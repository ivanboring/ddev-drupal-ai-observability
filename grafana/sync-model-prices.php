<?php

/**
 * Sync per-model token prices from https://models.dev/api.json into the
 * observability stack as OpenTelemetry gauge metrics.
 *
 * Metrics emitted (USD per 1,000,000 tokens), labelled {provider, model}:
 *   ai_model_price_input_usd_per_mtok
 *   ai_model_price_output_usd_per_mtok
 *   ai_model_price_cache_read_usd_per_mtok
 *
 * They are POSTed to Alloy's OTLP endpoint, which forwards them to Mimir.
 * The Grafana "AI Tokens & Cost" dashboard joins token counters against these
 * gauges (via last_over_time) to compute real spend. Re-run to refresh.
 *
 * Usage (inside the web container):  php .ddev/grafana/sync-model-prices.php
 */

$source   = getenv('MODELS_DEV_URL') ?: 'https://models.dev/api.json';
$endpoint = getenv('ALLOY_OTLP_URL') ?: 'http://grafana-alloy:4318/v1/metrics';

fwrite(STDERR, "Fetching model prices from $source ...\n");

$ch = curl_init($source);
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => TRUE,
  CURLOPT_TIMEOUT => 30,
  CURLOPT_FOLLOWLOCATION => TRUE,
]);
$body = curl_exec($ch);
if ($body === FALSE) {
  fwrite(STDERR, 'ERROR fetching models.dev: ' . curl_error($ch) . "\n");
  exit(1);
}
curl_close($ch);

$data = json_decode($body, TRUE);
if (!is_array($data)) {
  fwrite(STDERR, "ERROR: could not decode models.dev JSON\n");
  exit(1);
}

// Build one gauge data point per (metric, provider, model).
$now = (string) intval(microtime(TRUE) * 1e9);
$points = ['input' => [], 'output' => [], 'cache_read' => []];

foreach ($data as $providerId => $provider) {
  if (!is_array($provider) || empty($provider['models']) || !is_array($provider['models'])) {
    continue;
  }
  foreach ($provider['models'] as $modelId => $model) {
    $cost = $model['cost'] ?? NULL;
    if (!is_array($cost)) {
      continue;
    }
    foreach (['input', 'output', 'cache_read'] as $key) {
      if (!isset($cost[$key]) || !is_numeric($cost[$key])) {
        continue;
      }
      $points[$key][] = [
        'asDouble' => (float) $cost[$key],
        'timeUnixNano' => $now,
        'attributes' => [
          ['key' => 'provider', 'value' => ['stringValue' => (string) $providerId]],
          ['key' => 'model', 'value' => ['stringValue' => (string) $modelId]],
        ],
      ];
    }
  }
}

$metricName = [
  'input' => 'ai_model_price_input_usd_per_mtok',
  'output' => 'ai_model_price_output_usd_per_mtok',
  'cache_read' => 'ai_model_price_cache_read_usd_per_mtok',
];

$metrics = [];
foreach ($points as $key => $dps) {
  if (!$dps) {
    continue;
  }
  // No 'unit' — the Prometheus exporter would append it to the metric name
  // (e.g. ..._per_mtok_USD). The name already encodes the unit.
  $metrics[] = [
    'name' => $metricName[$key],
    'gauge' => ['dataPoints' => $dps],
  ];
}

$total = array_sum(array_map('count', $points));
if (!$total) {
  fwrite(STDERR, "ERROR: no priced models found in the source\n");
  exit(1);
}

$payload = json_encode([
  'resourceMetrics' => [[
    'resource' => [
      'attributes' => [
        ['key' => 'service.name', 'value' => ['stringValue' => 'model-prices']],
      ],
    ],
    'scopeMetrics' => [[
      'scope' => ['name' => 'models.dev'],
      'metrics' => $metrics,
    ]],
  ]],
]);

$ch = curl_init($endpoint);
curl_setopt_array($ch, [
  CURLOPT_RETURNTRANSFER => TRUE,
  CURLOPT_POST => TRUE,
  CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
  CURLOPT_POSTFIELDS => $payload,
  CURLOPT_TIMEOUT => 30,
]);
$resp = curl_exec($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
if ($resp === FALSE || $code >= 300) {
  fwrite(STDERR, "ERROR posting to Alloy ($endpoint): HTTP $code " . curl_error($ch) . "\n");
  exit(1);
}
curl_close($ch);

printf("Synced %d price points (%d input, %d output, %d cache_read) to %s [HTTP %d]\n",
  $total, count($points['input']), count($points['output']), count($points['cache_read']), $endpoint, $code);
