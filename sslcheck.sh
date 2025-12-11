#!/bin/bash
# 检测https证书有效期
dir_path="/usr/local/nginx/ssl"
line=$(find "$dir_path"  -maxdepth 1 -type d -not -name "default" -not -name "ssl" -printf "%f\n" );
for file in $line; do
  echo $file
  end_time=$(echo | timeout 1 openssl s_client -servername $file -connect $file:443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | awk -F '=' '{print $2}' )
  end_times=`date -d "$end_time" +%s `
  now_times=`date -d "$(date -u '+%b %d %T %Y GMT') " +%s `
  left_time=$(($end_times-$now_times))
  days=`expr $left_time / 86400`
  if [ $days -lt 3 ];then
    /root/.acme.sh/acme.sh --renew -d  $file --force
    systemctl restrt nginx
  fi
done