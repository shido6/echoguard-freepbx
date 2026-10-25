<?php
// Echo connector — FreePBX console page.
//
// Read-only status for the node this box is connected as. Everything shown
// here comes from two files:
//   /var/lib/echo-connector/node.json   node id, platform, endpoint (0644)
//   /var/lib/echo-connector/state.json  counters written by connector.py
//                                       (last_hep, last_send_ok, sent_total, errors)
// The node key lives in root-only /opt/echo-connector/agent.env and is never
// read here.

$state_dir = '/var/lib/echo-connector';

$read_json = static function (string $path): array {
    if (!is_readable($path)) {
        return [];
    }
    $raw = @file_get_contents($path);
    if ($raw === false) {
        return [];
    }
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
};

$node  = $read_json($state_dir . '/node.json');
$state = $read_json($state_dir . '/state.json');

$node_id    = (string) ($node['node_id'] ?? '');
$platform   = (string) ($node['platform'] ?? 'freepbx');
$endpoint   = (string) ($node['endpoint'] ?? 'https://echo.echoguard.ca');
$installed  = (string) ($node['installed_at'] ?? '');

$last_ok    = (int) ($state['last_send_ok'] ?? 0);
$last_hep   = (int) ($state['last_hep'] ?? 0);
$sent_total = (int) ($state['sent_total'] ?? 0);
$errors     = (int) ($state['errors'] ?? 0);

$age        = $last_ok > 0 ? max(0, time() - $last_ok) : null;
$hep_age    = $last_hep > 0 ? max(0, time() - $last_hep) : null;
$connected  = $age !== null && $age < 300;   // heartbeats are ~30s

$service = '';
if (is_executable('/bin/systemctl')) {
    $service = trim((string) @shell_exec('systemctl is-active echo-connector 2>/dev/null'));
}

$fresh = static function (?int $seconds): string {
    if ($seconds === null) {
        return 'never';
    }
    if ($seconds < 90) {
        return $seconds . 's ago';
    }
    if ($seconds < 5400) {
        return (int) round($seconds / 60) . 'm ago';
    }
    return (int) round($seconds / 3600) . 'h ago';
};
?>
<div class="container-fluid">
  <h1>Echo connector</h1>
  <p>
    This system sends <strong>SIP signalling</strong> to your Echo account so you can see
    registrations, call setup, and failures there. Signalling only &mdash; no audio, no
    recordings. The connector connects <strong>outbound</strong>; no inbound port is opened.
  </p>

  <?php if ($connected): ?>
    <div class="alert alert-success">
      <strong>Connected.</strong>
      Node <code><?php echo htmlspecialchars($node_id !== '' ? $node_id : 'unknown'); ?></code>
      last reported <?php echo htmlspecialchars($fresh($age)); ?>.
    </div>
  <?php elseif ($node_id === ''): ?>
    <div class="alert alert-warning">
      <strong>Not connected.</strong> Run the setup string from your Echo dashboard on this server.
    </div>
  <?php else: ?>
    <div class="alert alert-warning">
      <strong>Quiet.</strong>
      Node <code><?php echo htmlspecialchars($node_id); ?></code>
      last reported <?php echo htmlspecialchars($fresh($age)); ?>.
      Check <code>systemctl status echo-connector</code> and
      <code>tail /var/log/echo-connector/agent.log</code>.
    </div>
  <?php endif; ?>

  <h2>Status</h2>
  <table class="table table-condensed">
    <tr><th style="width:220px">Node</th>
        <td><code><?php echo htmlspecialchars($node_id !== '' ? $node_id : '(not configured)'); ?></code></td></tr>
    <tr><th>Platform</th><td><?php echo htmlspecialchars($platform); ?></td></tr>
    <tr><th>Endpoint</th><td><code><?php echo htmlspecialchars($endpoint); ?></code></td></tr>
    <tr><th>Service</th>
        <td><?php echo htmlspecialchars($service !== '' ? $service : 'unknown'); ?></td></tr>
    <tr><th>Last report</th><td><?php echo htmlspecialchars($fresh($age)); ?></td></tr>
    <tr><th>Last signal captured</th><td><?php echo htmlspecialchars($fresh($hep_age)); ?></td></tr>
    <tr><th>Events forwarded</th><td><?php echo (int) $sent_total; ?></td></tr>
    <tr><th>Send errors</th><td><?php echo (int) $errors; ?></td></tr>
    <?php if ($installed !== ''): ?>
    <tr><th>Installed</th><td><?php echo htmlspecialchars($installed); ?></td></tr>
    <?php endif; ?>
  </table>

  <h2>Connect another system</h2>
  <ol>
    <li>Sign in to <a href="<?php echo htmlspecialchars($endpoint); ?>" target="_blank" rel="noopener">Echo</a>.</li>
    <li>Press <strong>+ Connect a phone system</strong>, name it, and press
        <strong>Generate the one-line setup</strong>.</li>
    <li>On that server, paste that line as printed, or run
        <code>sudo ./install.sh 'EC-...'</code> from this package with the key it quoted.
        The key is shown once and expires in 24 hours if unused.</li>
    <li>Come back here &mdash; the status above turns green after the first report.</li>
  </ol>

  <h2>Remove</h2>
  <p>
    <code>sudo ./uninstall.sh</code> removes the connector, the local helper, and this page.
    Then revoke the node in the Echo dashboard so the key cannot be reused.
  </p>
</div>
