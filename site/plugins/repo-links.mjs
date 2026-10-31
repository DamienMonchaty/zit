// Links in Markdown, for a site served under a base path that also shows
// some of the repository's own files (the changelog, the privacy policy…).
// A Sätteri mdast plugin, Astro's Markdown processor.
//
// - A root link, `/start/install/`, gets the base: pages are written as if
//   the site were at the domain's root.
// - In a repository file, a relative link goes to that file's page here when
//   it has one, and to GitHub otherwise: `docs/PERF.md` is not on the site.
//   Its `# Title` is dropped, since the page already shows one.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const site = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const root = path.dirname(site);

/** Repository files that are a page of the site. */
const pages = {
	'README.md': '/',
	'CHANGELOG.md': '/project/changelog/',
	'CONTRIBUTING.md': '/project/contributing/',
	'PRIVACY.md': '/project/privacy/',
	'SECURITY.md': '/project/security/',
};

/** @param {{ base: string, blob: string }} options */
export default function repoLinks({ base, blob }) {
	const prefix = base.replace(/\/$/, '');
	const withBase = (url) => (url === prefix || url.startsWith(prefix + '/') ? url : prefix + url);

	return ({ fileURL }) => {
		const from = fileURL ? fileURLToPath(fileURL) : '';
		const inRepo = from !== '' && !from.startsWith(site + path.sep);

		const rewrite = (url) => {
			if (url.startsWith('/') && !url.startsWith('//')) return withBase(url);
			if (!inRepo || url.startsWith('#') || /^[a-z][a-z0-9+.-]*:/i.test(url)) return url;
			const [target, hash] = url.split('#');
			const file = path.relative(root, path.resolve(path.dirname(from), target)).split(path.sep).join('/');
			const anchor = hash ? '#' + hash : '';
			return file in pages ? withBase(pages[file]) + anchor : blob + file + anchor;
		};

		const relink = (node, ctx) => {
			const url = rewrite(node.url);
			if (url !== node.url) ctx.setProperty(node, 'url', url);
		};

		let titled = false;
		return {
			name: 'zit-repo-links',
			link: relink,
			definition: relink,
			heading(node, ctx) {
				if (!inRepo || titled || node.depth !== 1) return;
				titled = true;
				ctx.removeNode(node);
			},
		};
	};
}
