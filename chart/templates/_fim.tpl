{{- /*
Copyright IO ANALYTICA. All Rights Reserved.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Name of the watcher's resources (ConfigMap, Service, Deployment, ...).
*/}}
{{- define "wordpress.fim.fullname" -}}
{{- printf "%s-fim" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels of the watcher pod. Deliberately not the WordPress pod's
name label: the WordPress Service, NetworkPolicy and PDB select on
name+instance, and a watcher pod carrying both would receive web traffic.
*/}}
{{- define "wordpress.fim.matchLabels" -}}
app.kubernetes.io/name: {{ printf "%s-fim" (include "common.names.name" .) }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
SHA-256 of the wp-config.php the init container writes. A quoted heredoc
adds one newline after the last line, hence the "\n".
*/}}
{{- define "wordpress.fim.wpConfigDigest" -}}
{{- printf "%s\n" (include "wordpress.wpConfigPhp" .) | sha256sum -}}
{{- end -}}

{{/*
True when the volume can be mounted from several nodes.
*/}}
{{- define "wordpress.fim.volumeIsShared" -}}
{{- if or (has "ReadWriteMany" .Values.persistence.accessModes) (eq (toString .Values.persistence.accessMode) "ReadWriteMany") -}}
{{- true -}}
{{- end -}}
{{- end -}}

{{/*
The watcher's configuration, read by files/fim.php on every scan.
*/}}
{{- define "wordpress.fim.config" -}}
{{- $static := list -}}
{{- $mounts := list -}}
{{- if .Values.extraVolumeMounts -}}
{{- $mounts = include "common.tplvalues.render" (dict "value" .Values.extraVolumeMounts "context" .) | fromYamlArray -}}
{{- end -}}
{{- range $mounts -}}
{{- if and (eq (toString .name) "wordpress-data") .subPath (hasPrefix "/var/www/html/" (toString .mountPath)) -}}
{{- $static = append $static (dict "path" (trimPrefix "/var/www/html/" .mountPath | trimSuffix "/") "subPath" (trimSuffix "/" .subPath)) -}}
{{- end -}}
{{- end -}}
{{- range .Values.fim.extraPaths -}}
{{- $static = append $static (dict "path" (trimSuffix "/" .path) "subPath" (trimSuffix "/" .subPath)) -}}
{{- end -}}
{{- /* Drop-ins are checked against the copy their plugin ships, so a
       plugin update never needs a baseline refreshed. An empty value in
       fim.dropins removes an entry. */ -}}
{{- $dropins := dict -}}
{{- range $name := list "advanced-cache.php" "db.php" "object-cache.php" -}}
{{- $_ := set $dropins $name (printf "wp-content/plugins/w3-total-cache/wp-content/%s" $name) -}}
{{- end -}}
{{- range $name, $source := .Values.fim.dropins -}}
{{- if $source -}}
{{- $_ := set $dropins $name (trimPrefix "/" $source) -}}
{{- else -}}
{{- $_ := unset $dropins $name -}}
{{- end -}}
{{- end -}}
{{- $writable := list "wp-content/uploads/" -}}
{{- if not .Values.fim.allowMuPlugins -}}
{{- $writable = append $writable "wp-content/mu-plugins/" -}}
{{- end -}}
{{- $baseline := dict "wp-config.php" (list (include "wordpress.fim.wpConfigDigest" .)) -}}
{{- range $path, $digests := .Values.fim.baseline -}}
{{- $list := list -}}
{{- range (kindIs "string" $digests | ternary (list $digests) $digests) -}}
{{- /* An unquoted digest of digits and at most one "e" is a number to YAML,
       and its digits are gone before this template sees it. */ -}}
{{- if not (and (kindIs "string" .) (regexMatch "^[0-9a-fA-F]{64}$" .)) -}}
{{- fail (printf "fim.baseline[%s]: %v is not a SHA-256 hex digest - quote digests in values files" $path .) -}}
{{- end -}}
{{- $list = append $list (lower .) -}}
{{- end -}}
{{- if $list -}}
{{- $_ := set $baseline $path $list -}}
{{- else -}}
{{- $_ := unset $baseline $path -}}
{{- end -}}
{{- end -}}
{{- dict
    "root" "/watch"
    "core" "wordpress"
    "port" (int .Values.fim.port)
    "interval" (int .Values.fim.interval)
    "staticMounts" $static
    "allowMuPlugins" .Values.fim.allowMuPlugins
    "dropins" $dropins
    "allowedRootPhp" (.Values.fim.allowedRootPhp | default list | uniq)
    "allowedComponentRootFiles" (.Values.fim.allowedComponentRootFiles | default list | uniq)
    "writableDirs" (concat $writable .Values.fim.writableDirs | uniq)
    "nameMarkers" .Values.fim.nameMarkers
    "ignorePaths" .Values.fim.ignorePaths
    "baseline" $baseline
  | toPrettyJson -}}
{{- end -}}

{{/*
The watcher container, shared by both modes. In sidecar mode it has no
readiness probe: a watcher that is not ready must never take the WordPress
pod out of its Service.
*/}}
{{- define "wordpress.fim.container" -}}
- name: fim
  image: {{ include "wordpress.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy | quote }}
  command:
    - /usr/local/bin/php
    - -d
    - memory_limit=96M
    - /fim/fim.php
  ports:
    - name: fim-metrics
      containerPort: {{ .Values.fim.port }}
      protocol: TCP
  livenessProbe:
    httpGet:
      path: /metrics
      port: fim-metrics
    initialDelaySeconds: 10
    periodSeconds: 30
  {{- if ne .Values.fim.mode "sidecar" }}
  readinessProbe:
    httpGet:
      path: /metrics
      port: fim-metrics
    initialDelaySeconds: 5
  {{- end }}
  {{- with .Values.fim.resources }}
  resources: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.fim.containerSecurityContext }}
  securityContext: {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: wordpress-data
      mountPath: /watch
      readOnly: true
    - name: fim
      mountPath: /fim
      readOnly: true
{{- end -}}

{{/*
Volume holding the script and its configuration. Mounted as a directory, not
by subPath, so a configuration change reaches the running watcher.
*/}}
{{- define "wordpress.fim.volume" -}}
- name: fim
  configMap:
    name: {{ include "wordpress.fim.fullname" . }}
    defaultMode: 0444
{{- end -}}

{{/* Validate values of WordPress - File-integrity watcher */}}
{{- define "wordpress.validateValues.fim" -}}
{{- if .Values.fim.enabled -}}
{{- if not (has .Values.fim.mode (list "deployment" "sidecar")) -}}
wordpress: fim.mode
    Invalid value {{ .Values.fim.mode | quote }}.
    Allowed values are: deployment, sidecar.
{{- else if and (eq .Values.fim.mode "deployment") (not .Values.persistence.enabled) -}}
wordpress: fim.mode
    The watcher pod needs the WordPress volume, and without persistence there
    is none to share. Enable persistence or use fim.mode=sidecar.
{{- end -}}
{{- end -}}
{{- end -}}
