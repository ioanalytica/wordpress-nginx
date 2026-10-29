<?php
/*
 * Copyright IO ANALYTICA. All Rights Reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * File-integrity watcher for the WordPress volume (fim.enabled).
 *
 * Mounts the site's volume read-only and POLLS it. inotify is not an option:
 * the volume is typically RWX NFS, and inotify cannot see writes made by
 * another NFS client.
 *
 * Every scan runs in a forked child, so /metrics stays responsive however
 * long a scan takes, and a scan that dies or hangs never takes the endpoint
 * with it - a hung scan shows up as a stale wp_fim_last_scan_timestamp_seconds
 * instead. The child hands its result back over a socket pair.
 *
 * The configuration (/fim/config.json, rendered by the chart) is re-read on
 * every scan, so a baseline update reaches the watcher without a restart.
 * Only the port is read once.
 *
 * Paths are reported as the web server sees them, relative to the web root:
 * wp-content/..., wp-config.php, or the path of an extra volume mount.
 */

declare(strict_types=1);

const CONFIG_FILE = '/fim/config.json';
// More series than this and Prometheus pays for a flood of files that one
// alert already covers. wp_fim_violations keeps the exact count.
const MAX_SERIES = 1000;
const EXECUTABLE_EXT = ['.php', '.php3', '.php4', '.php5', '.php7', '.php8',
                        '.phtml', '.pht', '.phps', '.phar', '.inc', '.cgi', '.shtml'];
// Payload carriers: base64 has no code markers and no .php extension, so
// both a content scan and an extension filter miss it.
const CARRIER_EXT = ['.b64', '.bak', '.suspected', '.txt.php', '.php.txt'];

function load_config(): array
{
    $raw = @file_get_contents(CONFIG_FILE);
    if ($raw === false) {
        throw new RuntimeException('cannot read ' . CONFIG_FILE);
    }
    return json_decode($raw, true, 64, JSON_THROW_ON_ERROR);
}

function ends_with_any(string $name, array $suffixes): bool
{
    foreach ($suffixes as $s) {
        if (str_ends_with($name, $s)) {
            return true;
        }
    }
    return false;
}

function has_marker(string $name, array $markers): bool
{
    foreach ($markers as $m) {
        if ($m !== '' && str_contains($name, $m)) {
            return true;
        }
    }
    return false;
}

final class Scan
{
    /** @var array<string, array{rule: string, sha256?: string}> */
    public array $violations = [];
    private string $root;
    private string $core;
    private array $baseline;
    private array $ignore;
    private array $markers;

    public function __construct(private array $cfg)
    {
        $this->root = rtrim($cfg['root'], '/');
        $this->core = $this->root . '/' . $cfg['core'];
        $this->baseline = $cfg['baseline'] ?? [];
        $this->ignore = $cfg['ignorePaths'] ?? [];
        $this->markers = array_map('strtolower', $cfg['nameMarkers'] ?? []);
    }

    /** Presence rules skip baselined paths: those are judged by their digest. */
    private function flag(string $rel, string $rule): void
    {
        if (isset($this->baseline[$rel])) {
            return;
        }
        foreach ($this->ignore as $i) {
            if ($rel === $i || (str_ends_with($i, '/') && str_starts_with($rel, $i))) {
                return;
            }
        }
        $this->violations[$rel] = ['rule' => $rule];
    }

    /** null for a directory that does not exist, false for one that cannot be read. */
    private function entries(string $dir): array|false|null
    {
        if (!is_dir($dir)) {
            return null;
        }
        $names = @scandir($dir);
        return $names === false ? false : array_values(array_diff($names, ['.', '..']));
    }

    private static function is_real_dir(string $path): bool
    {
        // lstat: a symlink to a directory is not descended, and is checked
        // by its name like a file.
        $st = @lstat($path);
        return $st !== false && ($st['mode'] & 0170000) === 0040000;
    }

    /**
     * Walk a tree without following symlinks. A directory that cannot be read
     * is a finding of its own: a directory its owner made unreadable would
     * otherwise hide everything below it.
     *
     * @return iterable<array{0: string, 1: string}> [relative path, lowercased name]
     */
    private function walk(string $abs, string $rel): iterable
    {
        $stack = [[$abs, $rel]];
        while ($stack) {
            [$dir, $relDir] = array_pop($stack);
            $names = @scandir($dir);
            if ($names === false) {
                $this->flag($relDir === '' ? '.' : $relDir, 'unreadable');
                continue;
            }
            foreach ($names as $name) {
                if ($name === '.' || $name === '..') {
                    continue;
                }
                $p = $dir . '/' . $name;
                $r = $relDir === '' ? $name : $relDir . '/' . $name;
                if (self::is_real_dir($p)) {
                    $stack[] = [$p, $r];
                } else {
                    yield [$r, strtolower($name)];
                }
            }
        }
    }

    public function run(): void
    {
        $wc = $this->core . '/wp-content';

        if (empty($this->cfg['allowMuPlugins']) && is_dir($wc . '/mu-plugins')) {
            $this->flag('wp-content/mu-plugins', 'mu-plugins-dir');
        }

        $names = $this->entries($wc);
        if ($names === false || $names === null) {
            $this->flag('wp-content', 'unreadable');
        } else {
            $allowed = $this->cfg['allowedRootPhp'];
            foreach ($names as $name) {
                if (!in_array($name, $allowed, true)
                    && ends_with_any(strtolower($name), EXECUTABLE_EXT)
                    && !self::is_real_dir($wc . '/' . $name)) {
                    $this->flag('wp-content/' . $name, 'root-php');
                }
            }
        }

        // Every legitimate plugin and theme lives in its own subdirectory.
        // A loose file at the top of plugins/ or themes/ is where dropped
        // backdoors sit, whatever their name.
        $allowed = $this->cfg['allowedComponentRootFiles'];
        foreach (['plugins', 'themes'] as $comp) {
            $names = $this->entries($wc . '/' . $comp);
            if ($names === false) {
                $this->flag('wp-content/' . $comp, 'unreadable');
                continue;
            }
            foreach ($names ?? [] as $name) {
                if (!in_array($name, $allowed, true) && !self::is_real_dir($wc . '/' . $comp . '/' . $name)) {
                    $this->flag('wp-content/' . $comp . '/' . $name, 'loose-file-in-component-dir');
                }
            }
        }

        $writable = $this->cfg['writableDirs'];
        foreach ($this->walk($this->core, '') as [$rel, $low]) {
            if ($low === '.user.ini') {
                $this->flag($rel, 'user-ini');
            } elseif (ends_with_any($low, CARRIER_EXT)) {
                $this->flag($rel, 'encoded-carrier');
            } elseif (has_marker($low, $this->markers)) {
                $this->flag($rel, 'incident-marker');
            } elseif (ends_with_any($low, EXECUTABLE_EXT)) {
                foreach ($writable as $w) {
                    if (str_starts_with($rel, $w)) {
                        $this->flag($rel, 'php-in-writable-dir');
                        break;
                    }
                }
            }
        }

        // Further paths of the volume that are mounted into the web root.
        // They hold static content; anything executable there would be served.
        foreach ($this->cfg['staticMounts'] as $m) {
            $abs = $this->root . '/' . $m['subPath'];
            if (self::is_real_dir($abs)) {
                $files = $this->walk($abs, $m['path']);
            } elseif (file_exists($abs) || is_link($abs)) {
                $files = [[$m['path'], strtolower(basename($m['path']))]];
            } else {
                continue;
            }
            foreach ($files as [$rel, $low]) {
                if ($low === '.user.ini') {
                    $this->flag($rel, 'user-ini');
                } elseif (ends_with_any($low, EXECUTABLE_EXT) || ends_with_any($low, CARRIER_EXT)) {
                    $this->flag($rel, 'executable-in-static-path');
                } elseif (has_marker($low, $this->markers)) {
                    $this->flag($rel, 'incident-marker');
                }
            }
        }

        foreach ($this->baseline as $rel => $want) {
            $have = @hash_file('sha256', $this->resolve((string) $rel));
            if ($have === false) {
                $this->violations[$rel] = ['rule' => 'baseline-missing'];
            } elseif (!in_array($have, $want, true)) {
                // The digest found is part of the finding, so a legitimate
                // change can be re-baselined straight from the alert.
                $this->violations[$rel] = ['rule' => 'baseline-modified', 'sha256' => $have];
            }
        }
    }

    /** Map a web path to the volume: the longest matching static mount wins. */
    private function resolve(string $rel): string
    {
        $best = null;
        foreach ($this->cfg['staticMounts'] as $m) {
            $p = $m['path'];
            if (($rel === $p || str_starts_with($rel, $p . '/'))
                && ($best === null || strlen($p) > strlen($best['path']))) {
                $best = $m;
            }
        }
        if ($best !== null) {
            return $this->root . '/' . $best['subPath'] . substr($rel, strlen($best['path']));
        }
        return $this->core . '/' . $rel;
    }
}

function run_scan_child($sock): never
{
    $start = microtime(true);
    $interval = null;
    try {
        $cfg = load_config();
        $interval = (int) $cfg['interval'];
        $scan = new Scan($cfg);
        $scan->run();
        $violations = $scan->violations;
    } catch (Throwable $e) {
        fwrite(STDERR, 'scan failed: ' . $e->getMessage() . "\n");
        $violations = ['<scan>' => ['rule' => 'scan-error']];
    }
    $payload = json_encode([
        'violations' => $violations,
        'duration' => microtime(true) - $start,
        'interval' => $interval,
    ], JSON_INVALID_UTF8_SUBSTITUTE | JSON_THROW_ON_ERROR);
    for ($off = 0; $off < strlen($payload); $off += $n) {
        $n = fwrite($sock, substr($payload, $off));
        if ($n === false || $n === 0) {
            break;
        }
    }
    fclose($sock);
    exit(0);
}

function label(string $v): string
{
    return str_replace(['\\', '"', "\n"], ['\\\\', '\\"', '\\n'], $v);
}

function render_metrics(array $state): string
{
    $v = $state['violations'];
    ksort($v, SORT_STRING);
    $out = [
        '# HELP wp_fim_violation A file on the WordPress volume that breaks a file-integrity rule.',
        '# TYPE wp_fim_violation gauge',
    ];
    foreach (array_slice($v, 0, MAX_SERIES, true) as $path => $f) {
        $extra = isset($f['sha256']) ? sprintf(',sha256="%s"', label($f['sha256'])) : '';
        $out[] = sprintf('wp_fim_violation{path="%s",rule="%s"%s} 1', label((string) $path), label($f['rule']), $extra);
    }
    array_push(
        $out,
        '# HELP wp_fim_violations Number of file-integrity violations found by the last scan.',
        '# TYPE wp_fim_violations gauge',
        'wp_fim_violations ' . count($v),
        '# HELP wp_fim_last_scan_timestamp_seconds Completion time of the last scan.',
        '# TYPE wp_fim_last_scan_timestamp_seconds gauge',
        sprintf('wp_fim_last_scan_timestamp_seconds %.3f', $state['last_scan']),
        '# HELP wp_fim_scan_duration_seconds Duration of the last scan.',
        '# TYPE wp_fim_scan_duration_seconds gauge',
        sprintf('wp_fim_scan_duration_seconds %.3f', $state['duration']),
    );
    return implode("\n", $out) . "\n";
}

function serve($conn, array $state): void
{
    stream_set_timeout($conn, 2);
    $req = '';
    while (!str_contains($req, "\r\n\r\n") && strlen($req) < 8192) {
        $chunk = fread($conn, 8192);
        if ($chunk === false || $chunk === '') {
            break;
        }
        $req .= $chunk;
    }
    $line = strtok($req, "\r\n") ?: '';
    $parts = explode(' ', $line);
    $path = $parts[1] ?? '';
    if (($parts[0] ?? '') === 'GET' && ($path === '/metrics' || str_starts_with($path, '/metrics?'))) {
        $body = render_metrics($state);
        $head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\n";
    } else {
        $body = "not found\n";
        $head = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n";
    }
    @fwrite($conn, $head . 'Content-Length: ' . strlen($body) . "\r\nConnection: close\r\n\r\n" . $body);
    fclose($conn);
}

// PID 1 ignores signals it has no handler for; without these the pod would
// sit out its whole termination grace period.
pcntl_async_signals(true);
foreach ([SIGTERM, SIGINT] as $sig) {
    pcntl_signal($sig, static function (): void { exit(0); });
}

$cfg = load_config();
$port = (int) $cfg['port'];
$interval = (int) $cfg['interval'];
$server = @stream_socket_server('tcp://0.0.0.0:' . $port, $errno, $errstr);
if ($server === false) {
    fwrite(STDERR, "cannot listen on :$port: $errstr\n");
    exit(1);
}
fwrite(STDERR, "file-integrity watcher listening on :$port, scanning every {$interval}s\n");

$state = ['violations' => [], 'last_scan' => 0.0, 'duration' => 0.0];
$child = null;
$next = microtime(true);

while (true) {
    if ($child === null && microtime(true) >= $next) {
        $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
        $pid = $pair === false ? -1 : pcntl_fork();
        if ($pid === 0) {
            fclose($server);
            fclose($pair[0]);
            run_scan_child($pair[1]);
        }
        if ($pid === -1) {
            fwrite(STDERR, "cannot start a scan\n");
            $state['violations'] = ['<scan>' => ['rule' => 'scan-error']];
            $next = microtime(true) + $interval;
        } else {
            fclose($pair[1]);
            $child = ['pid' => $pid, 'sock' => $pair[0], 'buf' => ''];
        }
    }

    $read = [$server];
    if ($child !== null) {
        $read[] = $child['sock'];
    }
    $write = $except = null;
    if (@stream_select($read, $write, $except, 1) === false) {
        continue;
    }
    foreach ($read as $s) {
        if ($s === $server) {
            $conn = @stream_socket_accept($server, 0);
            if ($conn !== false) {
                serve($conn, $state);
            }
            continue;
        }
        $chunk = fread($s, 65536);
        if ($chunk !== false && $chunk !== '') {
            $child['buf'] .= $chunk;
            continue;
        }
        if (!feof($s)) {
            continue;
        }
        fclose($s);
        pcntl_waitpid($child['pid'], $status);
        $result = json_decode($child['buf'], true);
        if (!is_array($result) || !is_array($result['violations'] ?? null)) {
            fwrite(STDERR, "scan ended without a result\n");
            $result = ['violations' => ['<scan>' => ['rule' => 'scan-error']], 'duration' => 0.0, 'interval' => null];
        }
        $state = [
            'violations' => $result['violations'],
            'last_scan' => microtime(true),
            'duration' => (float) $result['duration'],
        ];
        if (is_int($result['interval']) && $result['interval'] > 0) {
            $interval = $result['interval'];
        }
        $child = null;
        $next = microtime(true) + $interval;
    }
}
