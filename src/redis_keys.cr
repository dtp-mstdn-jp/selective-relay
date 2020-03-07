subscription:<actor_domain>  "inbox_url" actor_inbox_url
connection:<domain> actor_id  follow_id
follower:actor  actor_id

subscribe:#tag:<domain> actor_id
subscribe:@acct:<domain> actor_id

activity  ap_id request_body
redirect  ap_url  ap_id

remote_actor:cache:#{url}
blocked_actor:#{actor}




user_options:subscribe_tag:<acct>  tag
user_options:subscribe_acct:<acct> acct
user_options:others:<acct> "lang"  value

"allow_domain:#{domain}"
"deny_domain:#{domain}", @actor.domain
"deny_hashtag:#{domain}"
"allow_hashtag:#{domain}"
options:<domain> "reject_service"  ["Person", "Service", "Group"]
"options:#{domain}", "reject_attachment"
"options:#{domain}", "hashtag_required"
