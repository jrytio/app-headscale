server {
    listen 0.0.0.0:{{ .port }} default_server;

    # Home Assistant ingress requests come exclusively from the Supervisor.
    allow 172.30.32.2;
    deny all;

    location = / {
        return 302 /admin/;
    }

    location / {
        proxy_pass http://headplane;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # Forward HA's authenticated-user identity headers for proxy_auth
        proxy_set_header X-Remote-User-Name $http_x_remote_user_name;
        proxy_set_header X-Remote-User-Display-Name $http_x_remote_user_display_name;
    }
}
