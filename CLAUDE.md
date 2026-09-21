# CLAUDE.md

You are an agent helping me with writing a Foundry Solidity project. Our workflow will work like so:
- I write pseudocode by hand
- I ask you questions as I develop
- I ask you to fill in the gaps turning the pseudocode into real code

We use license BUSL-1.1, and solc version 0.8.37. We use solady for our library needs. We use solady `SafeTransferLib` for all ERC20 transfers. To interact with a token (tests, integrations) import `IERC20` from `forge-std/interfaces/IERC20.sol` — solady ships no `IERC20`, its `tokens/ERC20.sol` is an abstract base for implementing one.

When asked to work on something you should try and remain as true to the pseudocode as possible. If you are unsure of what to do or there's a choice to be made, instead enter a "/// TODO: Decide X or help me understand Y" here with the minimum english required for me to know what I must specify to you. Then report at the end of your run how many TODOs you entered and where. 

## Edit Verbosity Levels
Being pseudocode I want to define levels of the quality here so I can have you do minimal cleanup at 1 level and produce full production ready code at another. The levels I can specify for an individual file/function/ect. If I don't specify a level, default to 1. Do not ever revert a level quality of code. Only up from 1 level to another for a given line.
1. Correct Solidity. Should compile, create any imports, variables, ect you need to make this happen. If impossible to do so or highly opinionated opt to do nothing and use the TODO system instead. Only focus on doing the bare minimum to get the code to compile. Don't worry about style or good practice.
2. Best Practices. Here we write the code with best practices for things like Events, Custom Errors, Named Imports, dry helper functions, ect. This makes the code larger and bulkier but correct. Here is important as a level because introducing these events/errors involve naming/variables I may want to check.
3. Production quality. The Solidity Style Guide must be followed, NATSPEC comments must exist on every external function. No unused variables, ect. You know what this looks like. 

Every assertion in a test gets a message string saying what failed. This applies at every level, level 1 included. A bare `assertEq(a, b)` tells me nothing when it fires.

I may ask you questions as well about decisions being made, in this case do not edit any code. 

In general limit yourself to the pseudocode and resist the urge to overdevelop or start on your own things. You may create interfaces if you need them from scratch. This is an iterative process and I will ask for what I need.

Interfaces are a mechanical copy of source that already exists. Writing one takes zero liberty. If the source does not exist yet, do not invent an interface for it — that is inventing my design. Import the contract that does not exist yet and TODO the parts you can't know. Structs never go in an interface, they go in the source contract.

The levels above describe the default working pattern. If I tell you we're working a different way for a stretch (writing tests before the source, say), my instruction wins over the level for as long as it holds. Under test-first specifically, not compiling is the correct state and level 1's "should compile" does not apply — do not bend the design to get a green build.

Do not rename functions and things without approval, as part of why I do the pseudocode is to have control over this. You may suggest these changes though with TODO if you think it's important.

We keep code clean. We keep things minimal. 

You do not write comments (besides the TODOs) unless specifically asked. 

If you uncover a serious security vulnerability or otherwise see a larger scope issue with the code. For example: you fill in some code in on a multichain vault project for an instantWithdraw function but realize that instantWithdraws allow users the ability to get free swaps using the vault and may arbitrage. If this happens you should flag me in the chat with a very short description (1 or 2 sentences) of the issue and your confidence in your understanding out of 10 and your ranking of the severity out of 10. I will then prompt you to explain more or not, or even ignore if I understand and am working around it.

When communicating with me, please remain concise, respect the aconym X WOL (Words Or Less) Ex. "a prompt for you 100 WOL". Avoid measured prose.

You may use this CLAUDE.md as an agent to keep notes, ect. Below. Do not edit all text above. The rules I have for communicating with me do not apply in the Claude zone. You may keep information in whatever format is most effective for you as an AI. I will not read it. 

== CLAUDE ZONE == 
