import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";

export default defineConfig({
	title: "DVAI-Bridge",
	description: "One local OpenAI server, embedded in your Web, iOS, Android, React Native, Flutter, or .NET app. Six SDKs, nine backends, one HTTP surface.",
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
		/superpowers\/(specs|plans)\//,
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
	srcExclude: ["superpowers/**", "marketing/**"],
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
					{ text: "Flutter SDK", link: "/guide/flutter-sdk" },
					{ text: ".NET SDK", link: "/guide/dotnet-sdk" },
					{ text: "MLX Backend", link: "/guide/mlx-backend" },
					{ text: "Model Distribution", link: "/guide/model-distribution" },
					{ text: "Multimodal", link: "/guide/multimodal" },
					{ text: "Tested Models", link: "/guide/tested-models" },
					{ text: "Auto-Recovery & Robustness", link: "/guide/auto-recovery" },
					{ text: "Distributed Inference (v3.0)", link: "/guide/distributed-inference" },
					{ text: "Self-Hosting Rendezvous (v3.0)", link: "/guide/self-hosting-rendezvous" },
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
				text: "Migration Guides",
				items: [
					{ text: "v1.5 → v1.6", link: "/migration/v1.5-to-v1.6" },
					{ text: "v1.6 → v2.0", link: "/migration/v1.6-to-v2.0" },
					{ text: "v2.0 → v2.1", link: "/migration/v2.0-to-v2.1" },
					{ text: "v2.1 → v2.2", link: "/migration/v2.1-to-v2.2" },
					{ text: "v2.2 → v2.3", link: "/migration/v2.2-to-v2.3" },
					{ text: "v2.3 → v2.4", link: "/migration/v2.3-to-v2.4" },
					{ text: "v2.4 → v3.0", link: "/migration/v2.4-to-v3.0" },
				],
			},
			{
				text: "Contributing",
				items: [
					{ text: "iOS native", link: "/development/contributing-ios" },
					{ text: "Android native", link: "/development/contributing-android" },
					{ text: "React Native", link: "/development/contributing-react-native" },
					{ text: "Flutter", link: "/development/contributing-flutter" },
					{ text: ".NET", link: "/development/contributing-dotnet" },
				],
			},
			{
				text: "Development",
				items: [
					{ text: "Testing", link: "/development/testing" },
					{ text: "Handler Parity", link: "/development/handler-parity" },
					{ text: "Mac Remote Builds", link: "/development/mac-remote-builds" },
					{ text: "Distributed Inference Testing (v3.0)", link: "/development/distributed-inference-testing" },
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
