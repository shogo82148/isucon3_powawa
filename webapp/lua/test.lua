local num = tonumber(ngx.var.arg_num) or 0

ngx.say("num is::", num)
