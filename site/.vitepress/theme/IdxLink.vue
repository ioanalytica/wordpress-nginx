<!-- Copyright IO ANALYTICA. SPDX-License-Identifier: Apache-2.0 -->
<!--
  A link to a file of wordpress-idx at the release the chart pins
  (idxImageTag in chart/Chart.yaml), so the page describes the sidecar the
  chart deploys. `raw` links to the file's plain text, for an agent to fetch.
-->
<script setup lang="ts">
import { computed } from 'vue';
import { useData } from 'vitepress';
import type { ThemeConfig } from '../config.mts';

const props = defineProps<{ file: string; raw?: boolean }>();
const { theme } = useData<ThemeConfig>();
const href = computed(() =>
  props.raw
    ? `https://raw.githubusercontent.com/ioanalytica/wordpress-idx/${theme.value.idxVersion}/${props.file}`
    : `https://github.com/ioanalytica/wordpress-idx/blob/${theme.value.idxVersion}/${props.file}`,
);
</script>

<template>
  <a :href="href" target="_blank" rel="noreferrer"><slot>{{ file }}</slot></a>
</template>
