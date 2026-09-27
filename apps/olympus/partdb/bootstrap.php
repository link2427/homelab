<?php
// Idempotent initial security setup; the token is provisioned separately.
require '/var/www/html/vendor/autoload.php';
(new Symfony\Component\Dotenv\Dotenv())->bootEnv('/var/www/html/.env');
$kernel = new App\Kernel('docker', false);
$kernel->boot();
$em = $kernel->getContainer()->get('doctrine')->getManager();
$users = $em->getRepository(App\Entity\UserSystem\User::class);
$anonymous = $users->findOneBy(['name' => 'anonymous']);
$anonymous->setGroup(null);
$structure = Symfony\Component\Yaml\Yaml::parseFile('/var/www/html/config/permissions.yaml');
foreach ($structure['perms'] as $permission => $definition) {
    foreach ($definition['operations'] as $operation => $_) {
        $anonymous->getPermissions()->setPermissionValue($permission, $operation, false);
    }
}
$users->findOneBy(['name' => 'admin'])->setDisabled(true);
$user = $users->findOneBy(['name' => 'jacob.neel@gmail.com']);
if (!$user) {
    $user = new App\Entity\UserSystem\User();
    $user->setName('jacob.neel@gmail.com');
    $user->setEmail('jacob.neel@gmail.com');
    $user->setFirstName('Jacob');
    $user->setLastName('Neel');
    $user->setSamlUser(true);
    $user->setNeedPwChange(false);
    $user->setGroup($em->find(App\Entity\UserSystem\Group::class, 1));
    $em->persist($user);
}
$em->flush();
echo "Anonymous permissions denied; bootstrap admin disabled; SAML user ready.\n";
