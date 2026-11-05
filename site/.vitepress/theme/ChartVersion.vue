<!-- Copyright IO ANALYTICA. SPDX-License-Identifier: Apache-2.0 -->
<!-- The chart's current version, read from chart/Chart.yaml at build time. -->
<script setup lang="ts">
import { useData } from 'vitepress';
import type { ThemeConfig } from '../config.mts';

const { theme } = useData<ThemeConfig>();
</script>

<template><code>{{ theme.chartVersion }}</code></template>
