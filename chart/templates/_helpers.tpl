{{- /*
Copyright IO ANALYTICA. All Rights Reserved.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/* vim: set filetype=mustache: */}}

{{/*
Return the proper WordPress image name.
Tag is read from Chart.yaml annotation "imageTag" (single source of truth).
*/}}
{{- define "wordpress.image" -}}
{{- $imageRoot := merge (dict "tag" (index .Chart.Annotations "imageTag")) .Values.image -}}
{{- include "common.images.image" (dict "imageRoot" $imageRoot "global" .Values.global) -}}
{{- end -}}

{{/*
Return the proper image name (for the metrics image)
*/}}
{{- define "wordpress.metrics.image" -}}
{{- include "common.images.image" (dict "imageRoot" .Values.metrics.image "global" .Values.global) -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "wordpress.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image .Values.metrics.image) "global" .Values.global) -}}
{{- end -}}

{{/*
 Create the name of the service account to use
 */}}
{{- define "wordpress.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "common.names.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Return the WordPress configuration secret
*/}}
{{- define "wordpress.configSecretName" -}}
{{- if .Values.existingWordPressConfigurationSecret -}}
    {{- printf "%s" (tpl .Values.existingWordPressConfigurationSecret $) -}}
{{- else -}}
    {{- printf "%s-configuration" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a secret object should be created for WordPress configuration
*/}}
{{- define "wordpress.createConfigSecret" -}}
{{- if and .Values.wordpressConfiguration (not .Values.existingWordPressConfigurationSecret) }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return the WordPress NGINX configuration configmap
*/}}
{{- define "wordpress.nginx.configmapName" -}}
{{- if .Values.existingNginxConfigurationConfigMap -}}
    {{- printf "%s" (tpl .Values.existingNginxConfigurationConfigMap $) -}}
{{- else -}}
    {{- printf "%s-nginx-configuration" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a configmap should be created for NGINX configuration
*/}}
{{- define "wordpress.nginx.createConfigmap" -}}
{{- if and .Values.nginxConfiguration (not .Values.existingNginxConfigurationConfigMap) }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return the WordPress NGINX server block addition
*/}}
{{- define "wordpress.nginx.serverblockConfigmapName" -}}
{{- if .Values.existingCustomServerBlockAdditionConfigMap -}}
    {{- printf "%s" (tpl .Values.existingCustomServerBlockAdditionConfigMap $) -}}
{{- else -}}
    {{- printf "%s-nginx-serverblock-addition" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a configmap should be created for NGINX server block addition
*/}}
{{- define "wordpress.nginx.createServerblockConfigmap" -}}
{{- if and .Values.nginxConfiguration (not .Values.existingNginxConfigurationConfigMap) }}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Hostname
*/}}
{{- define "wordpress.databaseHost" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "%s-mariadb" (include "common.names.fullname" .) -}}
{{- else -}}
    {{- printf "%s" .Values.externalDatabase.host -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Port
*/}}
{{- define "wordpress.databasePort" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "3306" -}}
{{- else -}}
    {{- printf "%d" (.Values.externalDatabase.port | int ) -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Host:Port
*/}}
{{- define "wordpress.databaseFullHost" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "%s-mariadb:3306" (include "common.names.fullname" .) -}}
{{- else -}}
    {{- printf "%s:%d" .Values.externalDatabase.host (.Values.externalDatabase.port | int ) -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Database Name
*/}}
{{- define "wordpress.databaseName" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "%s" .Values.mariadb.auth.database -}}
{{- else -}}
    {{- printf "%s" .Values.externalDatabase.database -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB User
*/}}
{{- define "wordpress.databaseUser" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "%s" .Values.mariadb.auth.username -}}
{{- else -}}
    {{- printf "%s" .Values.externalDatabase.user -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB charset
*/}}
{{- define "wordpress.databaseCharset" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "%s" (.Values.mariadb.databaseCharset | default "utf8mb4") -}}
{{- else -}}
    {{- printf "%s" ( default "utf8mb4" .Values.externalDatabase.databaseCharset ) -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB collation
*/}}
{{- define "wordpress.databaseCollation" -}}
{{- if .Values.mariadb.enabled }}
    {{- printf "%s" (.Values.mariadb.databaseCollation | default "") -}}
{{- else -}}
    {{- printf "%s" ( default "" .Values.externalDatabase.databaseCollation ) -}}
{{- end -}}
{{- end -}}

{{/*
Return the MariaDB Secret Name
*/}}
{{- define "wordpress.databaseSecretName" -}}
{{- if .Values.mariadb.enabled }}
    {{- if .Values.mariadb.auth.existingSecret -}}
        {{- printf "%s" .Values.mariadb.auth.existingSecret -}}
    {{- else -}}
        {{- printf "%s" (include "common.names.fullname" .) -}}
    {{- end -}}
{{- else if .Values.externalDatabase.existingSecret -}}
    {{- include "common.tplvalues.render" (dict "value" .Values.externalDatabase.existingSecret "context" $) -}}
{{- else -}}
    {{- printf "%s-externaldb" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return the cache hostname
*/}}
{{- define "wordpress.cacheHost" -}}
{{- if .Values.memcached.enabled }}
    {{- $releaseNamespace := .Release.Namespace }}
    {{- $clusterDomain := .Values.clusterDomain }}
    {{- printf "%s-cache.%s.svc.%s" (include "common.names.fullname" .) $releaseNamespace $clusterDomain -}}
{{- else -}}
    {{- printf "%s" .Values.externalCache.host -}}
{{- end -}}
{{- end -}}

{{/*
Return the cache port
*/}}
{{- define "wordpress.cachePort" -}}
{{- if .Values.memcached.enabled }}
    {{- if eq .Values.externalCache.type "redis" -}}
        {{- printf "6379" -}}
    {{- else -}}
        {{- printf "11211" -}}
    {{- end -}}
{{- else -}}
    {{- printf "%d" (.Values.externalCache.port | int ) -}}
{{- end -}}
{{- end -}}

{{/*
Return and validate the cache type
*/}}
{{- define "wordpress.cacheType" -}}
{{- $validCacheTypes := list "memcached" "redis" -}}
{{- if not (has .Values.externalCache.type $validCacheTypes) -}}
    {{- fail (printf "externalCache.type must be one of %v" $validCacheTypes) -}}
{{- end -}}
{{- printf "%s" .Values.externalCache.type -}}
{{- end -}}

{{/*
Return the WordPress Secret Name
*/}}
{{- define "wordpress.secretName" -}}
{{- if .Values.existingSecret }}
    {{- printf "%s" .Values.existingSecret -}}
{{- else -}}
    {{- printf "%s" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return the SMTP Secret Name
*/}}
{{- define "wordpress.smtpSecretName" -}}
{{- if .Values.smtpExistingSecret }}
    {{- printf "%s" .Values.smtpExistingSecret -}}
{{- else -}}
    {{- printf "%s" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Return the proper wordpress-idx image name.
Tag is read from Chart.yaml annotation "idxImageTag" (single source of truth).
*/}}
{{- define "wordpress.idx.image" -}}
{{- $imageRoot := merge (dict "tag" (index .Chart.Annotations "idxImageTag")) .Values.idx.image -}}
{{- include "common.images.image" (dict "imageRoot" $imageRoot "global" .Values.global) -}}
{{- end -}}

{{/*
Return the idx reindex API key secret name
*/}}
{{- define "wordpress.idx.reindexApiKeySecretName" -}}
{{- if .Values.idx.existingReindexApiKeySecret -}}
    {{- printf "%s" .Values.idx.existingReindexApiKeySecret -}}
{{- else -}}
    {{- printf "%s-idx" (include "common.names.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Validate ingress.ingressClassName when redirect is enabled. Must be one
of: nginx, nginx-traefik, traefik. Empty fails.

Class semantics for the REDIRECT:
  - nginx:
      Renders kind:Ingress with the `permanent-redirect` annotation.
      Served by rke2-ingress-nginx, drops the request path
      (nginx-ingress limitation, no path-preservation mechanism).
  - nginx-traefik, traefik:
      Both presume Traefik is present. The redirect is rendered as
      kind:Middleware (RedirectRegex with capture group) +
      kind:IngressRoute (uses ingressClassName: traefik, independent of
      the primary's class) + optional kind:Certificate. Path preserved.

      Pick nginx-traefik over traefik when the PRIMARY ingress needs the
      bridge provider to translate nginx-style annotations during
      migration; the redirect is identical between the two.

Usage: {{ include "wordpress.ingress.validateClass" . }}
*/}}
{{- define "wordpress.ingress.validateClass" -}}
{{- $allowed := list "nginx" "nginx-traefik" "traefik" -}}
{{- $cls := .Values.ingress.ingressClassName | default "" -}}
{{- if not (has $cls $allowed) -}}
{{- fail (printf "ingress.ingressClassName is required when redirect.enabled and must be one of %v; got %q" $allowed $cls) -}}
{{- end -}}
{{- end -}}

{{/*
Merged annotation map for the redirect Ingress (ingressClassName=nginx
path only): commonAnnotations + auto-injected permanent-redirect +
redirect.annotations. The IngressRoute path doesn't use annotations.
Usage: {{ include "wordpress.ingress.redirectAnnotations" . }}
*/}}
{{- define "wordpress.ingress.redirectAnnotations" -}}
{{- $base := default (dict) .Values.commonAnnotations -}}
{{- $auto := dict "nginx.ingress.kubernetes.io/permanent-redirect" .Values.redirect.targetUrl -}}
{{- $extra := default (dict) .Values.redirect.annotations -}}
{{- mergeOverwrite (deepCopy $base) $auto $extra | toYaml -}}
{{- end -}}

{{/*
Name of the redirect Middleware (traefik path). Used by both the
Middleware itself and the IngressRoute's middlewares reference.
Usage: {{ include "wordpress.redirect.middlewareName" . }}
*/}}
{{- define "wordpress.redirect.middlewareName" -}}
{{- printf "%s-redirect-preserve-path" (include "common.names.fullname" .) -}}
{{- end -}}

{{/*
Merged annotation map for the chart-emitted redirect resources on the
TRAEFIK path (Middleware, IngressRoute, Certificate): commonAnnotations
+ redirect.annotations. Mirrors the convention that every chart-emitted
resource carries top-level commonAnnotations, plus the redirect-specific
annotation overrides. No auto-injected nginx permanent-redirect on this
path (that's nginx-only, handled separately by redirectAnnotations).
Usage: {{ include "wordpress.redirect.traefikAnnotations" . }}
*/}}
{{- define "wordpress.redirect.traefikAnnotations" -}}
{{- $base := default (dict) .Values.commonAnnotations -}}
{{- $extra := default (dict) .Values.redirect.annotations -}}
{{- mergeOverwrite (deepCopy $base) $extra | toYaml -}}
{{- end -}}

{{/*
Returns the cluster-issuer name from redirect.annotations, or empty
string. Used to decide whether to emit a Certificate CR for the redirect
(traefik path). cert-manager's ingress-shim doesn't watch IngressRoute,
so for the traefik form we have to emit a standalone Certificate to get
a cert-manager-issued cert.
Usage: {{ include "wordpress.redirect.clusterIssuer" . }}
*/}}
{{- define "wordpress.redirect.clusterIssuer" -}}
{{- index (default (dict) .Values.redirect.annotations) "cert-manager.io/cluster-issuer" | default "" -}}
{{- end -}}

{{/*
Compile all warnings into a single message.
*/}}
{{- define "wordpress.validateValues" -}}
{{- $messages := list -}}
{{- $messages := append $messages (include "wordpress.validateValues.configuration" .) -}}
{{- $messages := append $messages (include "wordpress.validateValues.database" .) -}}
{{- $messages := append $messages (include "wordpress.validateValues.cache" .) -}}
{{- $messages := without $messages "" -}}
{{- $message := join "\n" $messages -}}
{{- if $message -}}
{{-   printf "\nVALUES VALIDATION:\n%s" $message | fail -}}
{{- end -}}
{{- end -}}

{{/*
Validate values of WordPress - Custom wp-config.php
*/}}
{{- define "wordpress.validateValues.configuration" -}}
{{- if and (or .Values.wordpressConfiguration .Values.existingWordPressConfigurationSecret) (not .Values.wordpressSkipInstall) -}}
wordpress: wordpressConfiguration
    You are trying to use a wp-config.php file. This setup is only supported
    when skipping wizard installation (--set wordpressSkipInstall=true).
{{- end -}}
{{- end -}}

{{/* Validate values of WordPress - Database */}}
{{- define "wordpress.validateValues.database" -}}
{{- if and (not .Values.mariadb.enabled) (or (empty .Values.externalDatabase.host) (empty .Values.externalDatabase.port) (empty .Values.externalDatabase.database)) -}}
wordpress: database
   You disabled the MariaDB installation but you did not provide the required parameters
   to use an external database. To use an external database, please ensure you provide
   (at least) the following values:

       externalDatabase.host=DB_SERVER_HOST
       externalDatabase.database=DB_NAME
       externalDatabase.port=DB_SERVER_PORT
{{- end -}}
{{- end -}}

{{/* Validate values of WordPress - Cache */}}
{{- define "wordpress.validateValues.cache" -}}
{{- if and .Values.wordpressConfigureCache (not .Values.memcached.enabled) (or (empty .Values.externalCache.host) (empty .Values.externalCache.port)) -}}
wordpress: cache
   You enabled cache via W3 Total Cache but you did not enable the internal cache server
   nor did you provide the required parameters to use an external cache server.
   Please enable the internal cache (--set memcached.enabled=true) or
   provide the external cache server values:

       externalCache.host=CACHE_SERVER_HOST
       externalCache.port=CACHE_SERVER_PORT
{{- end -}}
{{- end -}}
