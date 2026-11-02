#!/usr/bin/env bash
# Creates the two benchmark instances from nothing and sets them up with the repo's own scripts: box/setup-box.sh, the
# full seed and score/install-tools.sh on the target, the load generator and chain.sh on the other. About 20 minutes.
# Needs the multicore-target and multicore-loadgen security groups and the multicore-bench key pair. Refuses to run if
# either instance already exists; dev/aws/aws.sh up restarts stopped ones. To remove them, terminate them in EC2.
#
#   dev/aws/provision.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
if [ -z "${AWS_CONFIG_FILE:-}" ]; then export DIRENV_LOG_FORMAT=""; exec direnv exec "$ROOT" bash "$0" "$@"; fi
export AWS_PAGER=""
ZONE=us-east-1a
TYPE=c6a.2xlarge
GO_VERSION=1.27.2
SSH_OPTS=(-i "$HOME/.ssh/id_ed_personal" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o StrictHostKeyChecking=accept-new)
say() { printf '\n[provision %s] %s\n' "$(date +%T)" "$*"; }

existing=$(aws ec2 describe-instances --filters Name=tag:Project,Values=multicore-bench Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
[ -z "$existing" ] || { echo "instances already exist: $existing"; exit 1; }

AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=availability-zone,Values=$ZONE Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
group() { aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" --query 'SecurityGroups[0].GroupId' --output text; }

launch() { # name disk-gb
  local tags="{Key=Name,Value=$1},{Key=Project,Value=multicore-bench}"
  aws ec2 run-instances --image-id "$AMI" --instance-type "$TYPE" --key-name multicore-bench --count 1 \
    --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET,AssociatePublicIpAddress=true,Groups=$(group "$1")" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$2,VolumeType=gp3,DeleteOnTermination=true}" \
    --metadata-options HttpTokens=required \
    --tag-specifications "ResourceType=instance,Tags=[$tags]" "ResourceType=volume,Tags=[$tags]" \
    --query 'Instances[0].InstanceId' --output text
}

say "launching $TYPE instances from $AMI in $SUBNET"
TARGET_ID=$(launch multicore-target 100)
LOADGEN_ID=$(launch multicore-loadgen 30)
aws ec2 wait instance-running --instance-ids "$TARGET_ID" "$LOADGEN_ID"
describe() { aws ec2 describe-instances --instance-ids "$1" --query "Reservations[0].Instances[0].$2" --output text; }
TARGET=$(describe "$TARGET_ID" PublicIpAddress)
LOADGEN=$(describe "$LOADGEN_ID" PublicIpAddress)
PRIVATE=$(describe "$TARGET_ID" PrivateIpAddress)
# Four target addresses, as on the official box. dev/aws/aws.sh adds them to the interface inside the instance.
aws ec2 assign-private-ip-addresses --network-interface-id "$(describe "$TARGET_ID" 'NetworkInterfaces[0].NetworkInterfaceId')" --secondary-private-ip-address-count 3 >/dev/null
echo "target $TARGET_ID $TARGET ($PRIVATE), load generator $LOADGEN_ID $LOADGEN"

on() { ssh "${SSH_OPTS[@]}" "ubuntu@$1" "${@:2}"; }
for ip in "$TARGET" "$LOADGEN"; do
  for _ in $(seq 60); do on "$ip" true 2>/dev/null && break; sleep 5; done
  on "$ip" 'cloud-init status --wait >/dev/null || true'
done

say "copying the repo and installing Go $GO_VERSION on both"
for ip in "$TARGET" "$LOADGEN"; do
  rsync -az --delete -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" --exclude .git --exclude /submissions --exclude '/seed/data-*' --exclude /seed/.seedgen "$ROOT/" "ubuntu@$ip:/opt/challenge-repo/" &
  on "$ip" "set -e; curl -fsSL https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz -o /tmp/go.tgz; sudo rm -rf /usr/local/go; sudo tar -C /usr/local -xzf /tmp/go.tgz; rm /tmp/go.tgz" &
done
wait

say "load generator: limits, conduit-loadgen, chain.sh, ssh into the target"
on "$LOADGEN" "set -e; sudo apt-get update -q >/dev/null; sudo apt-get install -y -q rsync sysstat jq >/dev/null
  sudo install -m 644 /opt/challenge-repo/box/sysctl.conf /etc/sysctl.d/90-challenge.conf; sudo sysctl -q --system
  cd /opt/challenge-repo/bench; sudo env HOME=/root PATH=/usr/local/go/bin:\$PATH go build -o /usr/local/bin/conduit-loadgen ./cmd/loadgen
  sudo install -m 755 /opt/challenge-repo/score/chain.sh /root/chain.sh
  sudo mkdir -p /root/results /root/.ssh; sudo test -f /root/.ssh/id_ed25519 || sudo ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519"
LOADGEN_KEY=$(on "$LOADGEN" 'sudo cat /root/.ssh/id_ed25519.pub')

say "target: box/setup-box.sh"
on "$TARGET" "set -e; sudo bash /opt/challenge-repo/box/setup-box.sh 2>&1 | tail -6
  echo '$LOADGEN_KEY' | sudo tee /root/.ssh/authorized_keys >/dev/null"
on "$LOADGEN" "sudo sh -c 'ssh-keyscan $PRIVATE 2>/dev/null >> /root/.ssh/known_hosts'; sudo ssh -n -o BatchMode=yes root@$PRIVATE hostname"

say "target: full seed and scoring tools"
on "$TARGET" "set -e; sudo chown -R postgres /opt/challenge-repo/seed
  sudo -u postgres env HOME=/var/lib/postgresql PATH=/usr/local/go/bin:\$PATH bash /opt/challenge-repo/seed/make-seed.sh 2>&1 | tail -4
  sudo rm -rf /opt/challenge-repo/seed/data-*
  sudo bash /opt/challenge-repo/score/install-tools.sh | tail -2"

bash "$HERE/aws.sh" urls >/dev/null
say "done: target $TARGET, load generator $LOADGEN"
