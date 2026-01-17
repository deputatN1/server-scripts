server {
  listen 80;
  server_name {{DOMAIN}};
  
  root /var/www/{{DOMAIN}};
  index index.php index.html;
  
  location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
  
  location /admin {
    auth_basic "Demo Admin";
    auth_basic_user_file /etc/nginx/.htpasswd_{{DOMAIN}};
    try_files $uri $uri/ /index.php?$query_string;
  }

  location ~ \.php$ {
    include fastcgi_params;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
  }
  location ~ /\. {
        deny all;
    }
}

