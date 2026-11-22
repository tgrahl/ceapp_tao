<?php

/**
 * Set the password of TAO's default (install-time) admin user to TAO_ADMIN_PASSWORD.
 *
 * Non-interactive version of tao/scripts/resetRootPassword.php (same TAO calls). TAO only applies
 * TAO_ADMIN_PASSWORD at install time; use this to recover access, e.g. after the password file
 * was regenerated. tao-install.sh runs it only when TAO_RESET_ADMIN_PASSWORD=yes.
 * Run from the TAO root.
 */

use oat\generis\model\GenerisRdf;
use oat\tao\model\TaoOntology;

require getcwd() . '/tao/includes/raw_start.php';

$password = getenv('TAO_ADMIN_PASSWORD');
if ($password === false || $password === '') {
    fwrite(STDERR, "TAO_ADMIN_PASSWORD is empty – password not changed.\n");
    exit(1);
}

$user = new core_kernel_classes_Resource(LOCAL_NAMESPACE . TaoOntology::DEFAULT_USER_URI_SUFFIX);
$login = $user->getUniquePropertyValue(new core_kernel_classes_Property(GenerisRdf::PROPERTY_USER_LOGIN));

$hash = core_kernel_users_Service::getPasswordHash();
$success = $user->editPropertyValues(
    new core_kernel_classes_Property(GenerisRdf::PROPERTY_USER_PASSWORD),
    $hash->encrypt($password)
);

if (!$success) {
    fwrite(STDERR, "Could not change the password of TAO user '{$login}'.\n");
    exit(1);
}
echo "Password of TAO user '{$login}' set from TAO_ADMIN_PASSWORD.\n";
