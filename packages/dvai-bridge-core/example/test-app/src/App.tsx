import { useState } from "react";
import { DVAI } from "@dvai-bridge/core";
import { ChatOpenAI } from "@langchain/openai";
import { DynamicTool } from "langchain";
import "./App.css";

function App() {
	const [status, setStatus] = useState<
		"idle" | "loading" | "running" | "error" | "success"
	>("idle");
	const [result, setResult] = useState<string>("");

	const runTest = async () => {
		setStatus("loading");
		console.log("Initializing DVAI (Transformers Backend)...");

		try {
			const dvai = new DVAI({
				backend: "transformers",
				transformersModelId: "onnx-community/Llama-3.2-1B-Instruct-ONNX",
				pipelineTask: "text-generation",
				dtype: "q4",
				device: "auto",
				transformersWorkerUrl: "/dvai-transformers.worker.js",
			});

			await dvai.initialize((progress: { text: string; progress: number }) => {
				console.log(
					`Progress: ${progress.text} (${Math.round(progress.progress * 100)}%)`,
				);
			});

			setStatus("running");
			console.log("DVAI Ready. Setting up LangChain 1.x logic...");

			const model = new ChatOpenAI({
				apiKey: "not-needed",
				configuration: {
					baseURL: "https://api.openai.local/v1", // MSW will intercept this
				},
				temperature: 0,
			});

			const tools: Record<string, DynamicTool> = {
				get_current_time: new DynamicTool({
					name: "get_current_time",
					description: "Returns the current local time.",
					func: async () => new Date().toLocaleTimeString(),
				}),
			};

			const systemPrompt = `You are a helpful assistant. 
To use a tool, respond with a JSON object in this format:
{"tool": "tool_name", "args": {"arg1": "val1"}}

Available tools:
- get_current_time: Returns the current local time.

When you receive a tool result, use it to provide a final natural language answer to the user.`;

			const userMessage = "What time is it?";
			console.log(`Invoking model with: "${userMessage}"`);

			// Manual loop to handle tool calls for small models
			const messages: { role: string; content: string; name?: string }[] = [
				{ role: "system", content: systemPrompt },
				{ role: "user", content: userMessage },
			];

			let finalResponse = "";
			let iterations = 0;

			while (iterations < 5) {
				iterations++;
				const response = await model.invoke(messages);
				const content = (response.content as string).trim();
				console.log(`Model Response (Iteration ${iterations}):`, content);

				// Basic check for JSON tool call
				if (content.startsWith("{") && content.includes('"tool"')) {
					try {
						const toolCall = JSON.parse(content);
						if (toolCall.tool && tools[toolCall.tool]) {
							console.log(`Executing tool: ${toolCall.tool}`);
							const toolResult = await tools[toolCall.tool].func(
								JSON.stringify(toolCall.args),
							);
							console.log(`Tool Result:`, toolResult);

							// Push conversation history
							messages.push({ role: "assistant", content });
							// Use 'user' role for tool results to avoid coercion errors in LangChain
							// and to be more compatible with simple Llama 3 formatting.
							messages.push({
								role: "user",
								content: `TOOL_RESULT: ${toolResult}`,
							});
							continue;
						}
					} catch (e) {
						console.warn(
							"Iteration resulted in invalid JSON, treating as text:",
							e,
						);
					}
				}

				// If we're here, it's either not JSON or not a tool call: it's our final answer
				finalResponse = content;
				break;
			}

			setResult(finalResponse || "No response received.");
			console.log("Agent invocation successful.");
			setStatus("success");
		} catch (err: unknown) {
			const message = err instanceof Error ? err.message : String(err);
			console.log(`ERROR: ${message}`);
			console.error(err);
			setStatus("error");
		}
	};

	return (
		<div className="app-container">
			<h1>DVAI Transformers Repro</h1>
			<div className="controls">
				<button
					onClick={runTest}
					disabled={status === "loading" || status === "running"}
					className={status}
				>
					{status === "loading"
						? "Initializing..."
						: status === "running"
							? "Running..."
							: "Start Test"}
				</button>
			</div>

			<div className="status-badge">
				Status: <span className={status}>{status.toUpperCase()}</span>
			</div>

			{result && (
				<div className="result-container">
					<h3>Last Result:</h3>
					<code>{result}</code>
				</div>
			)}
		</div>
	);
}

export default App;
