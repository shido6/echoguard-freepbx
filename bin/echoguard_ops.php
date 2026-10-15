<?php
// EchoGuard bounded op executor — v0.1.
// Run as: php echoguard_ops.php <op> '<json args>'
// Exit code 0 = ok. stdout is a single JSON object.
// No free-form shell. No schema writes. Same allowlist as the cloud enforces.

error_reporting(E_ALL);

function out($data, $code = 0) {
    fwrite(STDOUT, json_encode($data));
    exit($code);
}

function sh($cmd, $timeout = 30) {
    $descriptors = [1 => ["pipe", "w"], 2 => ["pipe", "w"]];
    $proc = proc_open($cmd, $descriptors, $pipes, null, null, ["timeout" => $timeout]);
    if (!is_resource($proc)) {
        return ["code" => -1, "stdout" => "", "stderr" => "proc_open failed"];
    }
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($proc);
    return ["code" => $code, "stdout" => (string) $stdout, "stderr" => (string) $stderr];
}

$MODULE_ALLOWLIST = [
    "core", "pjsip", "sipsettings", "ivr", "timeconditions", "ringgroups",
    "queues", "miscapps", "customappctx", "confirm", "findmefollow",
];

$op = $argv[1] ?? "";
$args = json_decode($argv[2] ?? "{}", true) ?: [];

switch ($op) {
    case "snapshot": {
        $version = "unknown";
        if (is_readable("/etc/freepbx_version")) {
            foreach (file("/etc/freepbx_version", FILE_IGNORE_NEW_LINES) as $line) {
                if (strpos($line, "=") !== false) {
                    $version = trim(explode("=", $line, 2)[1]);
                    break;
                }
            }
        }
        $channels = sh("asterisk -rx 'core show channels count' 2>/dev/null");
        $uptime = sh("asterisk -rx 'core show uptime' 2>/dev/null");
        $disk = sh("df -P / /var 2>/dev/null | tail -n +2");
        $diskRows = [];
        foreach (explode("\n", trim($disk["stdout"])) as $row) {
            $parts = preg_split('/\s+/', $row);
            if (count($parts) >= 5) {
                $diskRows[] = ["mount" => $parts[5] ?? $parts[0], "used_pct" => $parts[4]];
            }
        }
        out([
            "freepbx_version" => $version,
            "asterisk_version" => trim(explode("\n", sh("asterisk -rx 'core show version' 2>/dev/null")["stdout"])[0] ?? ""),
            "active_channels" => trim($channels["stdout"]),
            "uptime" => trim($uptime["stdout"]),
            "disk" => $diskRows,
            "taken_at" => gmdate("c"),
        ]);
    }

    case "diagnose": {
        $regs = sh("asterisk -rx 'pjsip show registrations' 2>/dev/null");
        $endpoints = sh("asterisk -rx 'pjsip show endpoints' 2>/dev/null");
        $errors = sh("asterisk -rx 'core show channeltypes' 2>/dev/null");

        $regLines = array_values(array_filter(explode("\n", $regs["stdout"]), function ($l) {
            return stripos($l, "Registered") !== false || stripos($l, "Unregistered") !== false || stripos($l, "Rejected") !== false;
        }));
        $registered = 0;
        $rejected = 0;
        foreach ($regLines as $l) {
            if (stripos($l, "Registered") !== false) { $registered++; }
            if (stripos($l, "Rejected") !== false || stripos($l, "Unregistered") !== false) { $rejected++; }
        }

        $hints = [];
        if ($rejected > 0) {
            $hints[] = "One or more SIP registrations are rejected/unregistered — check trunk credentials and network reachability.";
        }
        $disk = sh("df -P / | tail -1");
        $parts = preg_split('/\s+/', trim($disk["stdout"]));
        $pct = (int) rtrim($parts[4] ?? "0", "%");
        if ($pct >= 90) {
            $hints[] = "Root filesystem is {$pct}% full.";
        }

        out([
            "registrations_registered" => $registered,
            "registrations_bad" => $rejected,
            "endpoint_block_lines" => count(array_filter(explode("\n", $endpoints["stdout"]))),
            "asterisk_responds" => $errors["code"] === 0,
            "disk_root_used_pct" => $pct,
            "hints" => $hints,
            "taken_at" => gmdate("c"),
        ]);
    }

    case "reload": {
        $r = sh("fwconsole reload 2>&1", 60);
        out([
            "ok" => $r["code"] === 0,
            "output" => substr($r["stdout"], -3000),
        ], $r["code"] === 0 ? 0 : 1);
    }

    case "module_reload": {
        $module = (string) ($args["module"] ?? "");
        if (!in_array($module, $MODULE_ALLOWLIST, true)) {
            out(["ok" => false, "error" => "module_not_allowed", "allowed" => $MODULE_ALLOWLIST], 1);
        }
        $r = sh("fwconsole reload " . escapeshellarg($module) . " 2>&1", 60);
        out([
            "ok" => $r["code"] === 0,
            "module" => $module,
            "output" => substr($r["stdout"], -3000),
        ], $r["code"] === 0 ? 0 : 1);
    }

    default:
        out(["ok" => false, "error" => "unknown_op", "op" => $op], 1);
}
