package conduit.contracts.user;

import conduit.contracts.user.readmodel.LoginUser;

public interface LoginReader {
    LoginUser byEmail(String email);
}
