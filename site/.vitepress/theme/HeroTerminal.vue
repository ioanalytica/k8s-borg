<!-- Copyright IO ANALYTICA. SPDX-License-Identifier: AGPL-3.0-only -->
<!-- The home page's hero image: the install, at the chart's current version. -->
<script setup lang="ts">
import { useData } from 'vitepress';
import type { ThemeConfig } from '../config.mts';

const { theme } = useData<ThemeConfig>();
</script>

<template>
  <figure class="hero-terminal">
    <div class="bar" aria-hidden="true"><span /><span /><span /></div>
    <pre><code><span class="c"># one release backs up the cluster</span>
<span class="p">$</span> helm install my-borg \
    oci://ghcr.io/ioanalytica/charts/k8s-borg \
    --version {{ theme.chartVersion }} \
    -n k8s-borg --create-namespace \
    -f values.yaml

<span class="c"># the cluster's archives, from the console pod</span>
<span class="p">$</span> kubectl -n k8s-borg exec \
    my-borg-k8s-borg-app-0 -- borg-list</code></pre>
  </figure>
</template>

<style scoped>
.hero-terminal {
  position: relative;
  margin: 0;
  width: min(100%, 480px);
  border-radius: 12px;
  background: var(--k8s-borg-terminal-bg);
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
  background: var(--k8s-borg-terminal-dot);
}

pre {
  margin: 0;
  padding: 14px 18px 18px;
  overflow-x: auto;
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
  line-height: 1.65;
  color: var(--k8s-borg-terminal-text);
}

.c {
  color: var(--k8s-borg-terminal-comment);
}

.p {
  color: var(--k8s-borg-terminal-prompt);
  user-select: none;
}

@media (max-width: 640px) {
  pre {
    font-size: 12px;
  }
}
</style>
