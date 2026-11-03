// Copyright IO ANALYTICA. SPDX-License-Identifier: AGPL-3.0-only
import type { Theme } from 'vitepress';
import DefaultTheme from 'vitepress/theme';
import { h } from 'vue';
// Jost, bundled with the site: no font service is contacted.
import '@fontsource/jost/400.css';
import '@fontsource/jost/400-italic.css';
import '@fontsource/jost/500.css';
import '@fontsource/jost/600.css';
import './custom.css';
import HeroTerminal from './HeroTerminal.vue';
import Mermaid from './Mermaid.vue';

export default {
  extends: DefaultTheme,
  Layout: () => h(DefaultTheme.Layout, null, { 'home-hero-image': () => h(HeroTerminal) }),
  enhanceApp({ app }) {
    app.component('Mermaid', Mermaid);
  },
} satisfies Theme;
