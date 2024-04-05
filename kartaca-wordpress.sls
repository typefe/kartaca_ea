# credentials from pilar
{% set mysql_database = salt['pillar.get']('mysql:database') %}
{% set mysql_username = salt['pillar.get']('mysql:username') %}
{% set mysql_password = salt['pillar.get']('mysql:password') %}

create_group_kartaca:
  group.present:
    - name: kartaca
    - gid: 2024

create_user_kartaca:
  user.present:
    - name: kartaca
    - shell: /bin/bash
    - home: /home/krt
    - uid: 2024
    - gid: 2024
    - password: {{ salt['pillar.get']('users:kartaca:password') }}
    - require:
        - group: kartaca

set_sudo_privileges:
  file.managed:
    - name: /etc/sudoers.d/kartaca
    - user: root
    - group: root
    - mode: 440
    - location: end
    {% if grains['os'] == 'CentOS Stream' %}
    - contents: |
        kartaca ALL=(ALL) NOPASSWD: /usr/bin/yum
    {% elif grains['os'] == 'Ubuntu' %}
    - contents: |
        kartaca ALL=(ALL) NOPASSWD: /usr/bin/apt
    {% endif %}
    - require:
        - user: kartaca

set_timezone:
  timezone.system:
    - name: Europe/Istanbul
    - utc: True

enable_ip_forwarding:
  sysctl.present:
    - name: net.ipv4.ip_forward
    - value: 1
    - config: /etc/sysctl.conf

install_required_packages:
  pkg.installed:
    - pkgs:
      {% if grains['os'] == 'CentOS Stream' %}
      - htop
      - cronie
      - traceroute
      - iputils
      - bind-utils
      - sysstat
      - mtr
      - logrotate
    - require:
      - pkg: install_epel_release
      {% elif grains['os'] == 'Ubuntu' %}
      - cron
      - gpg
      - htop
      - tcptraceroute
      - iputils-ping
      - dnsutils
      - sysstat
      - mtr
      {% endif %}

add_hashicorp_repo:
  cmd.run:
    {% if grains['os'] == 'CentOS Stream' %}
    - name: |
        wget -O- https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo | sudo tee /etc/yum.repos.d/hashicorp.repo
    {% elif grains['os'] == 'Ubuntu' %}
    - name: |
        sudo apt update && sudo apt install gpg
        wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        gpg --no-default-keyring --keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg --fingerprint
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
        sudo apt update
    {% endif %}

install_hashicorp_terraform:
  pkg.installed:
    - name: terraform
    {% if grains['os'] == 'CentOS Stream' %}
    - version: 1.6.4
    {% elif grains['os'] == 'Ubuntu' %}
    - version: 1.6.4-1
    {% endif %}
    - require:
      - cmd: add_hashicorp_repo

# add_host_record:
{% set subnet = '192.168.168.' %}
{% for i in range(128, 144) %}
add_host_record_{{ i }}:
  host.present:
    - ip: {{ subnet ~ i }}
    - names:
      - kartaca.local
{% endfor %}

{% if grains['os'] == 'CentOS Stream' %}

# for htop and someother repos
install_epel_release:
  pkg.installed:
    - name: epel-release

nginx:
  pkg.installed:
    - name: nginx
  service.running:
    - name: nginx
    - enable: True
    - reload: True
    - watch:
      - pkg: nginx
      - file: /etc/nginx/nginx.conf
  file.managed:
    - name: /etc/nginx/nginx.conf
    - source: salt://files/nginx.conf
    - user: root
    - group: root
    - mode: 640
    - require:
      - pkg: nginx
  
nginx_monthly_restart:
  cron.present:
    - name: 'sudo service nginx stop && sudo service nginx start'
    - user: root
    - minute: 0
    - hour: 0
    - daymonth: 1
    - require:
      - pkg: nginx

php_packages:
  pkg.installed:
    - pkgs:
      - php
      - php-cli
      - php-fpm
      - php-mysqlnd
      - php-gd
      - php-mbstring
      - php-xml
      - php-soap
      - php-intl

php_fpm_service:
  service.running:
    - name: php-fpm
    - enable: True
    - require:
      - pkg: php_packages

wordpress_setup:
  cmd.run:
    - name: | 
        cd /tmp && wget https://wordpress.org/latest.tar.gz && tar xf latest.tar.gz
        sudo mkdir -p /var/www/wordpress2024/ && sudo mv /tmp/wordpress/* /var/www/wordpress2024/
        mkdir /var/www/wordpress2024/logs/
        sudo chown -R nginx:nginx /var/www/wordpress2024/
        sudo chmod -R 755 /var/www/wordpress2024/
    - creates: /var/www/wordpress2024/

wordpress_secrets:
  cmd.run:
    - name: |
        sudo cp /var/www/wordpress2024/wp-config-sample.php /var/www/wordpress2024/wp-config.php
        wget -q -O - https://api.wordpress.org/secret-key/1.1/salt/ >> /var/www/wordpress2024/wp-config.php
    - creates: /var/www/wordpress2024/wp-config.php
    - require:
      - cmd: wordpress_setup

# change database credentials in wp-config.php
wordpress_db_credentials_dbname:
  file.replace:
    - name: /var/www/wordpress2024/wp-config.php
    - pattern: "define\\(\\s*'DB_NAME',\\s*'[^']*'\\s*\\);"
    - repl: "define( 'DB_NAME', '{{ mysql_database }}' );"
    - require:
      - cmd: wordpress_secrets

wordpress_db_credentials_user:
  file.replace:
    - name: /var/www/wordpress2024/wp-config.php
    - pattern: "define\\(\\s*'DB_USER',\\s*'[^']*'\\s*\\);"
    - repl: "define( 'DB_USER', '{{ mysql_username }}' );"
    - require:
      - cmd: wordpress_secrets

wordpress_db_credentials_password:
  file.replace:
    - name: /var/www/wordpress2024/wp-config.php
    - pattern: "define\\(\\s*'DB_PASSWORD',\\s*'[^']*'\\s*\\);"
    - repl: "define( 'DB_PASSWORD', '{{ mysql_password }}' );"
    - require:
      - cmd: wordpress_secrets

wordpress_db_credentials_host:
  file.replace:
    - name: /var/www/wordpress2024/wp-config.php
    - pattern: "define\\(\\s*'DB_HOST',\\s*'[^']*'\\s*\\);"
    - repl: "define( 'DB_HOST', 'kartaca.local' );"
    - require:
      - cmd: wordpress_secrets

ssl_configuration:
  file.managed:
    - name: /etc/ssl/kartaca.local.conf
    - source: salt://files/kartaca.local.conf
    - user: root
    - group: root
    - mode: 640

  cmd.run:
    - name: |
        cd /etc/ssl/
        sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout kartaca.local.key -out kartaca.local.crt -config kartaca.local.conf -subj "/C=TR/ST=Istanbul/L=Istanbul/O=kartaca.local/OU=kartacawordpress/CN=kartaca.local"
        mv kartaca.local.crt /etc/ssl/certs/kartaca.local.crt
        mkdir /etc/ssl/private/ ; mv kartaca.local.key /etc/ssl/private/kartaca.local.key
    - require:
      - file: /etc/ssl/kartaca.local.conf
    - creates: /etc/ssl/private/kartaca.local.key

nginx_logrotate:
  file.managed:
    - name: /etc/logrotate.d/nginx
    - source: salt://files/nginx
    - user: root
    - group: root
    - mode: 644
    - require:
      - pkg: install_required_packages

{% elif grains['os'] == 'Ubuntu' %}

mysql_server:
  pkg.installed:
    - name: mysql-server

mysql_service:
  service.running:
    - name: mysql
    - enable: True
    - watch:
      - pkg: mysql-server

create_mysql:
  cmd.run:
    - name: |
        mysql -u root -e "CREATE USER IF NOT EXISTS '{{ mysql_username }}'@'kartaca.local' IDENTIFIED BY '{{ mysql_password }}';"
        mysql -u root -e "CREATE DATABASE IF NOT EXISTS {{ mysql_database }} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
        mysql -u root -e "GRANT ALL PRIVILEGES ON {{ mysql_database }}.* TO '{{ mysql_username }}'@'kartaca.local';"
        mysql -u root -e "FLUSH PRIVILEGES;"
    - require:
      - pkg: mysql-server

mysql_backup:
  cron.present:
    - name: 'mysqldump -u {{ mysql_username }} -p{{ mysql_password }} {{ mysql_database }} > /backup/{{ mysql_database }}_$(date +\%Y\%m\%d).sql'
    - user: root
    - minute: 0
    - hour: 2
    - require:
      - pkg: mysql-server

{% endif %}