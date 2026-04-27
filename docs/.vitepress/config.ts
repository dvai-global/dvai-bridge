import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";

export default defineConfig({
	title: "DVAI-Bridge",
	description: "Local AI Orchestration for Web, Capacitor, and Electron",
	head: [
		[
			"script",
			{
				defer: "defer",
				src: "https://app.lemonsqueezy.com/js/lemon.js",
			},
		],
		["link", { rel: "icon", href: "/favicon.png", type: "image/x-png" }],
	],
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
	cleanUrls: true,
	vite: {
		plugins: [llmstxt()],
	},
	markdown: {
		linkify: false,
		image: {
			lazyLoading: true,
		},
	},
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
					{ text: "Capacitor Quickstart", link: "/guide/quickstart-capacitor" },
					{ text: "iOS Native SDK", link: "/guide/ios-native-sdk" },
					{ text: "Android Native SDK", link: "/guide/android-native-sdk" },
					{ text: "React Native SDK", link: "/guide/react-native-sdk" },
					{ text: "MLX Backend", link: "/guide/mlx-backend" },
					{ text: "Model Distribution", link: "/guide/model-distribution" },
					{ text: "Multimodal", link: "/guide/multimodal" },
					{ text: "Tested Models", link: "/guide/tested-models" },
					{ text: "Auto-Recovery & Robustness", link: "/guide/auto-recovery" },
					{ text: "vs. Other Tools", link: "/guide/comparison" },
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
			{
				text: "Development",
				items: [
					{ text: "Testing", link: "/development/testing" },
					{ text: "Handler Parity", link: "/development/handler-parity" },
					{ text: "Mac Remote Builds", link: "/development/mac-remote-builds" },
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
