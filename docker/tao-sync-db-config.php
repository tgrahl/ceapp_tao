<?php

/**
 * Keep TAO's stored database connection (config/generis/persistences.conf.php) in line with the
 * deployment's TAO_DB_HOST / TAO_DB_NAME / TAO_DB_USER / TAO_DB_PASSWORD.
 *
 * The installer saves these once. Every deployment, however, sets the MySQL admin password from
 * MYSQL_ADMIN_PASSWORD, so after a password change TAO fails with
 * "SQLSTATE[HY000] [1045] Access denied". Run from the TAO root (tao-install.sh does this on every
 * deployment). Uses TAO's service manager, which reads and writes the config file itself.
 *
 * Usage: php tao-sync-db-config.php            update the config if needed
 *        php tao-sync-db-config.php --check    only test the stored connection (exit 1 on failure)
 */

use oat\generis\persistence\PersistenceManager;
use oat\oatbox\service\ServiceManager;

require getcwd() . '/tao/includes/raw_start.php';

$serviceManager = ServiceManager::getServiceManager();
/** @var PersistenceManager $persistenceManager */
$persistenceManager = $serviceManager->get(PersistenceManager::SERVICE_ID);

if (in_array('--check', $argv, true)) {
    try {
        $persistenceManager->getPersistenceById('default')->query('SELECT 1');
        echo "Database connection OK\n";
        exit(0);
    } catch (\Throwable $e) {
        fwrite(STDERR, 'Database connection failed: ' . $e->getMessage() . "\n");
        exit(1);
    }
}

$persistences = $persistenceManager->getOption('persistences');
if (!isset($persistences['default']['connection']) || !is_array($persistences['default']['connection'])) {
    fwrite(STDERR, "No 'default' SQL persistence with a 'connection' found – nothing updated.\n");
    exit(1);
}

$fields = [
    'host' => 'TAO_DB_HOST',
    'dbname' => 'TAO_DB_NAME',
    'user' => 'TAO_DB_USER',
    'password' => 'TAO_DB_PASSWORD',
];

$changed = [];
foreach ($fields as $key => $env) {
    $value = getenv($env);
    if ($value === false || $value === '') {
        continue;
    }
    if (($persistences['default']['connection'][$key] ?? null) !== $value) {
        $persistences['default']['connection'][$key] = $value;
        $changed[] = $key;
    }
}

if ($changed === []) {
    echo "Stored database connection matches the deployment – no change.\n";
    exit(0);
}

$persistenceManager->setOption('persistences', $persistences);
$serviceManager->register(PersistenceManager::SERVICE_ID, $persistenceManager);
echo 'Updated stored database connection: ' . implode(', ', $changed) . "\n";
