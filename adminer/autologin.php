<?php
class AutoLogin extends Adminer {
    private $server;
    private $username;
    private $password;
    private $database;

    public function __construct() {
        $this->server   = getenv('ADMINER_DEFAULT_SERVER') ?: '10.10.10.89';
        $this->username = getenv('POSTGRES_USER')          ?: 'postgres';
        $this->password = getenv('POSTGRES_PASSWORD')      ?: '';
        $this->database = getenv('POSTGRES_DB')            ?: 'packiot';
    }

    // Pre-fill server/user/password into the login form.
    public function credentials() {
        return [$this->server, $this->username, $this->password];
    }

    // Authentik is the real gate — always allow the attempt here.
    public function login($login, $password) {
        return true;
    }

    // Auto-submit the login form and land directly on the target database.
    public function loginForm() {
        $server = htmlspecialchars($this->server,   ENT_QUOTES);
        $db     = htmlspecialchars($this->database, ENT_QUOTES);
        echo "<script>document.addEventListener('DOMContentLoaded',function(){"
           . "var f=document.querySelector('#content form');"
           . "if(f){f.setAttribute('action','?pgsql={$server}&db={$db}');f.submit();}"
           . "});</script>";
        return true;
    }
}
