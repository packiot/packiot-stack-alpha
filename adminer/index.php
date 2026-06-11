<?php
function adminer_object() {
    include_once 'autologin.php';
    return new AutoLogin();
}
include 'adminer.php';
