#ifndef API_HANDLERS_H
#define API_HANDLERS_H

#include "api/api.h"

void handle_tags_list(api_request *r);

void handle_users_register(api_request *r);
void handle_users_login(api_request *r);
void handle_user_get(api_request *r);
void handle_user_update(api_request *r);

void handle_profile_get(api_request *r);
void handle_profile_follow(api_request *r);
void handle_profile_unfollow(api_request *r);

void handle_articles_list(api_request *r);
void handle_articles_feed(api_request *r);
void handle_article_get(api_request *r);
void handle_article_create(api_request *r);
void handle_article_update(api_request *r);
void handle_article_delete(api_request *r);

void handle_favorite_add(api_request *r);
void handle_favorite_remove(api_request *r);

void handle_comments_list(api_request *r);
void handle_comments_create(api_request *r);
void handle_comment_delete(api_request *r);

#endif
