package com.challenge.conduit.json;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufInputStream;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Fast streaming JSON reader using Jackson Core (already bundled with Vert.x).
 * Reads directly from Netty ByteBuf input stream without tree-model overhead.
 */
public final class JsonReader {

    private static final JsonFactory FACTORY = new JsonFactory();

    public record UserRegisterRequest(String username, String email, String password, boolean valid) {}
    public record UserLoginRequest(String email, String password, boolean valid) {}
    public record UserUpdateRequest(
            String username, boolean hasUsername,
            String email, boolean hasEmail,
            String password, boolean hasPassword,
            String bio, boolean hasBio,
            String image, boolean hasImage,
            boolean valid
    ) {}
    public record ArticleCreateRequest(String title, String description, String body, List<String> tagList, boolean valid) {}
    public record ArticleUpdateRequest(
            String title, boolean hasTitle,
            String description, boolean hasDescription,
            String body, boolean hasBody,
            boolean valid
    ) {}
    public record CommentCreateRequest(String body, boolean valid) {}

    public static UserRegisterRequest parseUserRegister(ByteBuf buf) {
        if (buf == null || buf.readableBytes() == 0) {
            return new UserRegisterRequest(null, null, null, false);
        }
        try (InputStream in = new ByteBufInputStream(buf);
             JsonParser p = FACTORY.createParser(in)) {

            if (p.nextToken() != JsonToken.START_OBJECT) return new UserRegisterRequest(null, null, null, false);

            String username = null, email = null, password = null;
            boolean insideUser = false;

            while (p.nextToken() != null) {
                JsonToken t = p.currentToken();
                if (t == JsonToken.FIELD_NAME) {
                    String name = p.currentName();
                    p.nextToken();
                    if ("user".equals(name)) {
                        if (p.currentToken() != JsonToken.START_OBJECT) {
                            return new UserRegisterRequest(null, null, null, false);
                        }
                        insideUser = true;
                    } else if (insideUser) {
                        if ("username".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new UserRegisterRequest(null, null, null, false);
                            username = p.getText();
                        } else if ("email".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new UserRegisterRequest(null, null, null, false);
                            email = p.getText();
                        } else if ("password".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new UserRegisterRequest(null, null, null, false);
                            password = p.getText();
                        } else {
                            p.skipChildren();
                        }
                    } else {
                        p.skipChildren();
                    }
                } else if (t == JsonToken.END_OBJECT && insideUser) {
                    insideUser = false;
                }
            }

            if (username == null || username.isEmpty() ||
                email == null || email.isEmpty() ||
                password == null || password.isEmpty() || password.getBytes().length > 72) {
                return new UserRegisterRequest(null, null, null, false);
            }

            return new UserRegisterRequest(username, email, password, true);
        } catch (Exception e) {
            return new UserRegisterRequest(null, null, null, false);
        }
    }

    public static UserLoginRequest parseUserLogin(ByteBuf buf) {
        if (buf == null || buf.readableBytes() == 0) {
            return new UserLoginRequest(null, null, false);
        }
        try (InputStream in = new ByteBufInputStream(buf);
             JsonParser p = FACTORY.createParser(in)) {

            if (p.nextToken() != JsonToken.START_OBJECT) return new UserLoginRequest(null, null, false);

            String email = null, password = null;
            boolean insideUser = false;

            while (p.nextToken() != null) {
                JsonToken t = p.currentToken();
                if (t == JsonToken.FIELD_NAME) {
                    String name = p.currentName();
                    p.nextToken();
                    if ("user".equals(name)) {
                        if (p.currentToken() != JsonToken.START_OBJECT) {
                            return new UserLoginRequest(null, null, false);
                        }
                        insideUser = true;
                    } else if (insideUser) {
                        if ("email".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new UserLoginRequest(null, null, false);
                            email = p.getText();
                        } else if ("password".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new UserLoginRequest(null, null, false);
                            password = p.getText();
                        } else {
                            p.skipChildren();
                        }
                    } else {
                        p.skipChildren();
                    }
                } else if (t == JsonToken.END_OBJECT && insideUser) {
                    insideUser = false;
                }
            }

            if (email == null || email.isEmpty() || password == null || password.isEmpty()) {
                return new UserLoginRequest(null, null, false);
            }

            return new UserLoginRequest(email, password, true);
        } catch (Exception e) {
            return new UserLoginRequest(null, null, false);
        }
    }

    public static UserUpdateRequest parseUserUpdate(ByteBuf buf) {
        if (buf == null || buf.readableBytes() == 0) {
            return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
        }
        try (InputStream in = new ByteBufInputStream(buf);
             JsonParser p = FACTORY.createParser(in)) {

            if (p.nextToken() != JsonToken.START_OBJECT) {
                return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
            }

            String username = null, email = null, password = null, bio = null, image = null;
            boolean hasUsername = false, hasEmail = false, hasPassword = false, hasBio = false, hasImage = false;
            boolean insideUser = false;
            boolean foundUserObject = false;

            while (p.nextToken() != null) {
                JsonToken t = p.currentToken();
                if (t == JsonToken.FIELD_NAME) {
                    String name = p.currentName();
                    p.nextToken();
                    if ("user".equals(name)) {
                        if (p.currentToken() != JsonToken.START_OBJECT) {
                            return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                        }
                        insideUser = true;
                        foundUserObject = true;
                    } else if (insideUser) {
                        if ("username".equals(name)) {
                            if (p.currentToken() == JsonToken.VALUE_STRING) {
                                username = p.getText();
                                if (username.isEmpty()) return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                                hasUsername = true;
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                // null means unchanged
                            } else {
                                return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                            }
                        } else if ("email".equals(name)) {
                            if (p.currentToken() == JsonToken.VALUE_STRING) {
                                email = p.getText();
                                if (email.isEmpty()) return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                                hasEmail = true;
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                // null means unchanged
                            } else {
                                return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                            }
                        } else if ("password".equals(name)) {
                            if (p.currentToken() == JsonToken.VALUE_STRING) {
                                password = p.getText();
                                if (password.isEmpty() || password.getBytes().length > 72) return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                                hasPassword = true;
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                // null means unchanged
                            } else {
                                return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                            }
                        } else if ("bio".equals(name)) {
                            if (p.currentToken() == JsonToken.VALUE_STRING) {
                                bio = p.getText();
                                hasBio = true;
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                // null means unchanged
                            } else {
                                return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                            }
                        } else if ("image".equals(name)) {
                            if (p.currentToken() == JsonToken.VALUE_STRING) {
                                image = p.getText();
                                hasImage = true;
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                // null means unchanged
                            } else {
                                return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
                            }
                        } else {
                            p.skipChildren();
                        }
                    } else {
                        p.skipChildren();
                    }
                } else if (t == JsonToken.END_OBJECT && insideUser) {
                    insideUser = false;
                }
            }

            if (!foundUserObject) {
                return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
            }

            return new UserUpdateRequest(username, hasUsername, email, hasEmail, password, hasPassword, bio, hasBio, image, hasImage, true);
        } catch (Exception e) {
            return new UserUpdateRequest(null, false, null, false, null, false, null, false, null, false, false);
        }
    }

    public static ArticleCreateRequest parseArticleCreate(ByteBuf buf) {
        if (buf == null || buf.readableBytes() == 0) {
            return new ArticleCreateRequest(null, null, null, null, false);
        }
        try (InputStream in = new ByteBufInputStream(buf);
             JsonParser p = FACTORY.createParser(in)) {

            if (p.nextToken() != JsonToken.START_OBJECT) return new ArticleCreateRequest(null, null, null, null, false);

            String title = null, description = null, body = null;
            List<String> tagList = null;
            boolean insideArticle = false;

            while (p.nextToken() != null) {
                JsonToken t = p.currentToken();
                if (t == JsonToken.FIELD_NAME) {
                    String name = p.currentName();
                    p.nextToken();
                    if ("article".equals(name)) {
                        if (p.currentToken() != JsonToken.START_OBJECT) {
                            return new ArticleCreateRequest(null, null, null, null, false);
                        }
                        insideArticle = true;
                    } else if (insideArticle) {
                        if ("title".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new ArticleCreateRequest(null, null, null, null, false);
                            title = p.getText();
                        } else if ("description".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new ArticleCreateRequest(null, null, null, null, false);
                            description = p.getText();
                        } else if ("body".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new ArticleCreateRequest(null, null, null, null, false);
                            body = p.getText();
                        } else if ("tagList".equals(name)) {
                            if (p.currentToken() == JsonToken.START_ARRAY) {
                                tagList = new ArrayList<>();
                                while (p.nextToken() != JsonToken.END_ARRAY) {
                                    if (p.currentToken() != JsonToken.VALUE_STRING) {
                                        return new ArticleCreateRequest(null, null, null, null, false);
                                    }
                                    String item = p.getText();
                                    if (item == null || item.isEmpty()) {
                                        return new ArticleCreateRequest(null, null, null, null, false);
                                    }
                                    tagList.add(item);
                                }
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                tagList = new ArrayList<>();
                            } else {
                                return new ArticleCreateRequest(null, null, null, null, false);
                            }
                        } else {
                            p.skipChildren();
                        }
                    } else {
                        p.skipChildren();
                    }
                } else if (t == JsonToken.END_OBJECT && insideArticle) {
                    insideArticle = false;
                }
            }

            if (title == null || title.isEmpty() ||
                description == null || description.isEmpty() ||
                body == null || body.isEmpty()) {
                return new ArticleCreateRequest(null, null, null, null, false);
            }

            if (tagList == null) {
                tagList = new ArrayList<>();
            }

            return new ArticleCreateRequest(title, description, body, tagList, true);
        } catch (Exception e) {
            return new ArticleCreateRequest(null, null, null, null, false);
        }
    }

    public static ArticleUpdateRequest parseArticleUpdate(ByteBuf buf) {
        if (buf == null || buf.readableBytes() == 0) {
            return new ArticleUpdateRequest(null, false, null, false, null, false, false);
        }
        try (InputStream in = new ByteBufInputStream(buf);
             JsonParser p = FACTORY.createParser(in)) {

            if (p.nextToken() != JsonToken.START_OBJECT) {
                return new ArticleUpdateRequest(null, false, null, false, null, false, false);
            }

            String title = null, description = null, body = null;
            boolean hasTitle = false, hasDescription = false, hasBody = false;
            boolean insideArticle = false;
            boolean foundArticleObject = false;

            while (p.nextToken() != null) {
                JsonToken t = p.currentToken();
                if (t == JsonToken.FIELD_NAME) {
                    String name = p.currentName();
                    p.nextToken();
                    if ("article".equals(name)) {
                        if (p.currentToken() != JsonToken.START_OBJECT) {
                            return new ArticleUpdateRequest(null, false, null, false, null, false, false);
                        }
                        insideArticle = true;
                        foundArticleObject = true;
                    } else if (insideArticle) {
                        if ("title".equals(name)) {
                            if (p.currentToken() == JsonToken.VALUE_STRING) {
                                title = p.getText();
                                if (title.isEmpty()) return new ArticleUpdateRequest(null, false, null, false, null, false, false);
                                hasTitle = true;
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                // null means unchanged
                            } else {
                                return new ArticleUpdateRequest(null, false, null, false, null, false, false);
                            }
                        } else if ("description".equals(name)) {
                            if (p.currentToken() == JsonToken.VALUE_STRING) {
                                description = p.getText();
                                if (description.isEmpty()) return new ArticleUpdateRequest(null, false, null, false, null, false, false);
                                hasDescription = true;
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                // null means unchanged
                            } else {
                                return new ArticleUpdateRequest(null, false, null, false, null, false, false);
                            }
                        } else if ("body".equals(name)) {
                            if (p.currentToken() == JsonToken.VALUE_STRING) {
                                body = p.getText();
                                if (body.isEmpty()) return new ArticleUpdateRequest(null, false, null, false, null, false, false);
                                hasBody = true;
                            } else if (p.currentToken() == JsonToken.VALUE_NULL) {
                                // null means unchanged
                            } else {
                                return new ArticleUpdateRequest(null, false, null, false, null, false, false);
                            }
                        } else {
                            p.skipChildren();
                        }
                    } else {
                        p.skipChildren();
                    }
                } else if (t == JsonToken.END_OBJECT && insideArticle) {
                    insideArticle = false;
                }
            }

            if (!foundArticleObject) {
                return new ArticleUpdateRequest(null, false, null, false, null, false, false);
            }

            return new ArticleUpdateRequest(title, hasTitle, description, hasDescription, body, hasBody, true);
        } catch (Exception e) {
            return new ArticleUpdateRequest(null, false, null, false, null, false, false);
        }
    }

    public static CommentCreateRequest parseCommentCreate(ByteBuf buf) {
        if (buf == null || buf.readableBytes() == 0) {
            return new CommentCreateRequest(null, false);
        }
        try (InputStream in = new ByteBufInputStream(buf);
             JsonParser p = FACTORY.createParser(in)) {

            if (p.nextToken() != JsonToken.START_OBJECT) return new CommentCreateRequest(null, false);

            String body = null;
            boolean insideComment = false;

            while (p.nextToken() != null) {
                JsonToken t = p.currentToken();
                if (t == JsonToken.FIELD_NAME) {
                    String name = p.currentName();
                    p.nextToken();
                    if ("comment".equals(name)) {
                        if (p.currentToken() != JsonToken.START_OBJECT) {
                            return new CommentCreateRequest(null, false);
                        }
                        insideComment = true;
                    } else if (insideComment) {
                        if ("body".equals(name)) {
                            if (p.currentToken() != JsonToken.VALUE_STRING) return new CommentCreateRequest(null, false);
                            body = p.getText();
                        } else {
                            p.skipChildren();
                        }
                    } else {
                        p.skipChildren();
                    }
                } else if (t == JsonToken.END_OBJECT && insideComment) {
                    insideComment = false;
                }
            }

            if (body == null || body.isEmpty()) {
                return new CommentCreateRequest(null, false);
            }

            return new CommentCreateRequest(body, true);
        } catch (Exception e) {
            return new CommentCreateRequest(null, false);
        }
    }
}
