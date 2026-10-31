// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { satteri } from '@astrojs/markdown-satteri';
import repoLinks from './plugins/repo-links.mjs';

// Published by .github/workflows/pages.yml at damienmonchaty.github.io/zit.
const site = 'https://damienmonchaty.github.io';
const base = '/zit';
const repo = 'https://github.com/DamienMonchaty/zit';

export default defineConfig({
	site,
	base,
	markdown: {
		processor: satteri({ mdastPlugins: [repoLinks({ base, blob: `${repo}/blob/main/` })] }),
	},
	integrations: [
		starlight({
			title: 'Zit',
			description: 'A fast, native desktop Git client for Linux and Windows, written in Zig.',
			logo: { src: '../src/brand/zit-icon-256.png', alt: '' },
			favicon: '/favicon.png',
			social: [{ icon: 'github', label: 'GitHub', href: repo }],
			editLink: { baseUrl: `${repo}/edit/develop/site/` },
			customCss: [
				'@fontsource-variable/inter',
				'@fontsource/jetbrains-mono/400.css',
				'./src/styles/zit.css',
			],
			sidebar: [
				{
					label: 'Start here',
					items: ['start/install', 'start/github'],
				},
				{
					label: 'Using Zit',
					items: ['guides/features', 'guides/search', 'guides/keyboard'],
				},
				{
					label: 'Project',
					items: [
						'project/performance',
						'project/under-the-hood',
						'project/contributing',
						'project/changelog',
						'project/privacy',
						'project/security',
					],
				},
			],
		}),
	],
});
