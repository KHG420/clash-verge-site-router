# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Existing Ruby standard-library CLI. The authorized extension adds a local HTML/CSS/JavaScript interface using the same Ruby management services. No build step, cloud account, remote assets, or production gems. This follows the user's instruction to choose routine reversible implementation details autonomously.

## Users

People using several existing Clash Verge Rev subscriptions on one desktop, who want to assign websites, understand quota and expiry, and manage updates without editing configuration files.

## Product Purpose

Make subscriptions, their website assignments, pending changes, and runtime status visible together. Applying a change succeeds only when the live routing has been verified.

## Operating Context

Chinese desktop interface; macOS first. Clash Verge owns the source subscription registry and proxy process. This tool owns only its website routing extensions and local management preferences. Subscription quota is cached, with its update time shown; unknown data stays unknown.

## Capabilities and Constraints

The user authorized subscription overview, an interactive menu, route diagnostics, apply/reactivate/verify, batch refresh and drift handling, node preferences within a subscription, expiry/quota alerts, scenarios, credential-free import/export, and an inspectable takeover of existing manual routing. The local panel serves the same capabilities. Existing rules, credentials, and user browser sessions must be preserved. Subscription URLs and secrets must never appear in API responses, logs, exports, or the public repository.

## Product Principles

- One source for subscription identity: the existing client registry.
- Show saved intent separately from verified runtime state.
- Preview changes and preserve recoverable history.
- Keep a website inside its chosen subscription.
- Explain failures with a concrete next action.

## Confirmed Interface Approach

The user chose a lightweight interface implemented directly in code, retaining the existing Ruby project. The panel operates in Chinese and runs only on the user's computer.
