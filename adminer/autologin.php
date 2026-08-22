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
        // Default DB = the live single plane, packiot_analytics (F3). The old
        // POSTGRES_DB fallback pointed at the retired F1 `packiot` plane (audit
        // 2026-08-21, M7). ADMINER_DEFAULT_DB lets compose override it explicitly.
        $this->database = getenv('ADMINER_DEFAULT_DB') ?: (getenv('POSTGRES_DB') ?: 'packiot_analytics');
    }

    // Pre-fill server/user/password into the login form.
    public function credentials() {
        return [$this->server, $this->username, $this->password];
    }

    // Authentik is the real gate — always allow the attempt here.
    public function login($login, $password) {
        return true;
    }

    // Two-step auto-login:
    // Step 1 (no ?pgsql in URL): redirect to ?pgsql=server&db=db so Adminer
    //   pre-fills the DB field from the URL query param.
    // Step 2 (has ?pgsql): inject auto-submit script, then call parent to
    //   render the actual server/user/pass/db input fields inside the form.
    //   DOMContentLoaded submits the now-populated #content form.
    public function loginForm() {
        $server = urlencode($this->server);
        $db     = urlencode($this->database);
        $nonce  = \Adminer\get_nonce();
        echo "<script nonce='{$nonce}'>"
           . "if(location.search.indexOf('pgsql')<0){"
           .   "location.replace('?pgsql={$server}&db={$db}');"
           . "}else{"
           .   "document.addEventListener('DOMContentLoaded',function(){"
           .     "var f=document.querySelector('#content form');"
           .     "if(f)f.submit();"
           .   "});"
           . "}"
           . "</script>";
        return parent::loginForm();
    }
}
