# Foreign keys already guarantee these; validating them would cost a SELECT per association on every insert.
ActiveRecord::Base.belongs_to_required_by_default = false

# Timestamps are stored as timestamptz and always rendered in UTC; plain Time objects are enough.
ActiveRecord::Base.time_zone_aware_attributes = false
ActiveRecord.default_timezone = :utc
