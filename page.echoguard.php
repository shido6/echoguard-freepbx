<?php
// EchoGuard connector — GUI settings page (v0.1).
// Shows the setup instructions and current agent status. The agent itself is a
// standalone systemd service (bin/echoguard-agent.py) that talks outbound only.

$conf_file = '/etc/echoguard/agent.conf';
$conf = [];
if (is_readable($conf_file)) {
    foreach (file($conf_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if ($line[0] === '#' || strpos($line, '=') === false) {
            continue;
        }
        [$k, $v] = explode('=', $line, 2);
        $conf[trim($k)] = trim($v);
    }
}

$status = [];
$status_file = '/var/lib/echoguard/last-status.json';
if (is_readable($status_file)) {
    $decoded = json_decode((string) file_get_contents($status_file), true);
    if (is_array($decoded)) {
        $status = $decoded;
    }
}

$connected = !empty($status['ok']);
?>
<div class="container">
  <h1>EchoGuard Connector</h1>
  <p>
    This connector lets EchoGuard take <strong>snapshots</strong> and run a small set of
    <strong>bounded diagnostics</strong> on this phone system, and issue
    <strong>reload</strong> commands when you ask for them from your EchoGuard console.
    The agent makes outbound HTTPS connections only — it opens no inbound ports.
  </p>

  <?php if ($connected): ?>
    <div class="alert alert-success">
      Agent last checked in: <?php echo htmlspecialchars($status['checked_in'] ?? 'unknown'); ?> ·
      node <?php echo htmlspecialchars($status['node_id'] ?? '?'); ?>
    </div>
  <?php else: ?>
    <div class="alert alert-warning">
      Agent is not connected yet (or has not checked in). Run <code>sudo /usr/local/bin/echoguard-agent --status</code> on this server.
    </div>
  <?php endif; ?>

  <h2>Setup (one time)</h2>
  <ol>
    <li>In your EchoGuard console, add a FreePBX system — you get a one-line setup command.</li>
    <li>On this server, download the installer from your console and run the setup command it printed.</li>
    <li>Return here — the status above turns green once the agent checks in.</li>
  </ol>

  <h2>What the agent will run</h2>
  <ul>
    <li><code>snapshot</code> — versions, channel counts, disk headroom</li>
    <li><code>diagnose</code> — registrations, trunk health, recent Asterisk errors</li>
    <li><code>reload</code> — a standard FreePBX/Asterisk reload</li>
    <li><code>module_reload</code> — reload of one allowlisted module (core, pjsip, ivr, …)</li>
  </ul>
  <p>There is no free-form shell access and no schema/destination editing in this version.</p>

  <h2>Current config</h2>
  <p>
    Endpoint: <code><?php echo htmlspecialchars($conf['endpoint'] ?? '(not configured)'); ?></code><br>
    Node: <code><?php echo htmlspecialchars($conf['node_id'] ?? '(not configured)'); ?></code>
  </p>
</div>
