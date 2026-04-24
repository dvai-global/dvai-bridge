import { defineConfig } from "vitepress";

export default defineConfig({
	title: "DVAI-Bridge",
	description: "Local AI Orchestration for Web, Capacitor, and Electron",
	// Ignore dead links that point outside the published docs tree:
	// - `../../CHANGELOG` from `docs/migration/*.md` resolves to the repo-root
	//   CHANGELOG.md (not a VitePress page).
	// - Planning docs under `docs/superpowers/` contain illustrative markdown
	//   samples that reference sibling docs from a different on-disk location;
	//   they are design artifacts, not part of the published site.
	ignoreDeadLinks: [
		/CHANGELOG(\.md)?$/,
		/^\/?superpowers\//,
		/^\.\.\/guide\/transports/,
	],
	srcExclude: ["superpowers/**"],
	themeConfig: {
		logo: "/logo.png",
		nav: [
			{ text: "Guide", link: "/guide/introduction" },
			{ text: "Reference", link: "/reference/api" },
			{ text: "GitHub", link: "https://github.com/Westenets/dvai-bridge" },
		],
		sidebar: [
			{
				text: "Guide",
				items: [
					{ text: "Introduction", link: "/guide/introduction" },
					{ text: "Getting Started", link: "/guide/getting-started" },
					{ text: "Backends", link: "/guide/backends" },
					{ text: "Transports", link: "/guide/transports" },
					{ text: "Native LLM (Capacitor)", link: "/guide/native-backend" },
					{ text: "Auto-Recovery & Robustness", link: "/guide/auto-recovery" },
				],
			},
			{
				text: "API Reference",
				items: [
					{ text: "Core Options", link: "/reference/api" },
					{ text: "React Hooks", link: "/reference/react" },
					{ text: "Vanilla JS", link: "/reference/vanilla" },
				],
			},
		],
		socialLinks: [
			{ icon: "github", link: "https://github.com/Westenets/dvai-bridge" },
		],
		footer: {
			message: "Released under Custom License.",
			copyright:
				'Copyright © 2024-present <a href="https://deepvoiceai.co" target="_blank" rel="noopener">Deep Voice AI Limited</a>',
		},
	},
});
