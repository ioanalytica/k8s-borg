<!-- Copyright IO ANALYTICA. SPDX-License-Identifier: AGPL-3.0-only -->
<!-- A ```mermaid block (see mermaidFences in config.mts), drawn in the
     browser in the site's colours, again whenever light or dark changes. -->
<script setup lang="ts">
import { onMounted, ref, useId, watch } from 'vue';
import { useData } from 'vitepress';

const props = defineProps<{ code: string }>();
const { isDark } = useData();
const svg = ref('');
const id = `mermaid-${useId()}`;

async function draw() {
  const { default: mermaid } = await import('mermaid');
  // Mermaid sizes the boxes by measuring their labels: in a fallback font,
  // the labels outgrow their boxes once Jost is there.
  await document.fonts.load('400 16px Jost').catch(() => {});
  await document.fonts.ready;
  const css = getComputedStyle(document.documentElement);
  const v = (name: string) => css.getPropertyValue(name).trim();
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: 'base',
    fontFamily: v('--vp-font-family-base'),
    themeVariables: {
      darkMode: isDark.value,
      background: v('--vp-c-bg'),
      primaryColor: v('--vp-c-bg-soft'),
      primaryBorderColor: v('--vp-c-brand-1'),
      primaryTextColor: v('--vp-c-text-1'),
      lineColor: v('--vp-c-text-2'),
      clusterBkg: v('--vp-c-bg-alt'),
      clusterBorder: v('--vp-c-divider'),
      titleColor: v('--vp-c-text-1'),
      edgeLabelBackground: v('--vp-c-bg'),
    },
  });
  svg.value = (await mermaid.render(id, decodeURIComponent(props.code))).svg;
}

onMounted(draw);
watch(isDark, draw, { flush: 'post' });
</script>

<template>
  <div class="mermaid-diagram" v-html="svg" />
</template>

<style scoped>
.mermaid-diagram {
  margin: 16px 0;
  overflow-x: auto;
  text-align: center;
}

/* Mermaid measured its labels at its own line height; the page's paragraph
   style would make them taller than their boxes. */
.mermaid-diagram :deep(p) {
  margin: 0;
  line-height: inherit;
}
</style>
