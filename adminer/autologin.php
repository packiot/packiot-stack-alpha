<?php
class AutoLogin extends \Adminer\Adminer {
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

    // Render a hidden form and auto-submit it with the request nonce so it
    // passes Adminer 5's strict-dynamic CSP (which ignores 'unsafe-inline').
    public function loginForm() {
        $server = htmlspecialchars($this->server,   ENT_QUOTES);
        $user   = htmlspecialchars($this->username, ENT_QUOTES);
        $pass   = htmlspecialchars($this->password, ENT_QUOTES);
        $db     = htmlspecialchars($this->database, ENT_QUOTES);
        $nonce  = \Adminer\get_nonce();
        echo "<form id='_al' method='post' action='?pgsql={$server}&db={$db}'>"
           . "<input type='hidden' name='auth[driver]'   value='pgsql'>"
           . "<input type='hidden' name='auth[server]'   value='{$server}'>"
           . "<input type='hidden' name='auth[username]' value='{$user}'>"
           . "<input type='hidden' name='auth[password]' value='{$pass}'>"
           . "<input type='hidden' name='auth[db]'       value='{$db}'>"
           . "</form>"
           . "<script nonce='{$nonce}'>var f=document.getElementById('_al');document.body.appendChild(f);f.submit();</script>";
        return true;
    }
}
