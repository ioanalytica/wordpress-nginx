<!-- Copyright IO ANALYTICA. SPDX-License-Identifier: Apache-2.0 -->
<!-- The home page's hero image: the install, at the chart's current version. -->
<script setup lang="ts">
import { useData } from 'vitepress';
import type { ThemeConfig } from '../config.mts';

const { theme } = useData<ThemeConfig>();
</script>

<template>
  <figure class="hero-terminal">
    <div class="bar" aria-hidden="true"><span /><span /><span /></div>
    <pre><code><span class="c"># WordPress on NGINX, with its own MariaDB</span>
<span class="p">$</span> helm install my-wordpress \
    oci://ghcr.io/ioanalytica/charts/wordpress-nginx \
    --version {{ theme.chartVersion }} \
    --set ingress.enabled=true \
    --set ingress.hostname=blog.example.com

<span class="c"># the pods of the release</span>
<span class="p">$</span> kubectl get pods \
    -l app.kubernetes.io/instance=my-wordpress</code></pre>
  </figure>
</template>

<style scoped>
.hero-terminal {
  position: relative;
  margin: 0;
  width: min(100%, 480px);
  border-radius: 12px;
  background: var(--wp-nginx-terminal-bg);
  box-shadow: var(--vp-shadow-4);
  overflow: hidden;
  text-align: left;
}

.bar {
  display: flex;
  gap: 6px;
  padding: 12px 14px 0;
}

.bar span {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: var(--wp-nginx-terminal-dot);
}

pre {
  margin: 0;
  padding: 14px 18px 18px;
  overflow-x: auto;
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
  line-height: 1.65;
  color: var(--wp-nginx-terminal-text);
}

.c {
  color: var(--wp-nginx-terminal-comment);
}

.p {
  color: var(--wp-nginx-terminal-prompt);
  user-select: none;
}

@media (max-width: 640px) {
  pre {
    font-size: 12px;
  }
}
</style>
