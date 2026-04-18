import { defineConfig } from "vitepress";

export default defineConfig({
	title: "DVAI-Bridge",
	description: "Local AI Orchestration for Web, Capacitor, and Electron",
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
