#!/bin/bash
set -u
set -e
umask 0077
export PATH='/bin:/usr/bin'
export LANG='C'

mysql -uroot -proot isucon << _EOT_
create index i_memos_1 on memos (is_private, created_at);
create index i_memos_2 on memos (user, created_at);
create index i_memos_2 on memos (user, is_private, created_at);
_EOT_
