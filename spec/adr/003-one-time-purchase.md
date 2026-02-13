# ADR-003: One-Time Purchase Pricing Model

> Status: **HISTORICAL** - Pricing decision remains current; entitlement/trial mechanics are superseded by ADR-006.
> Date: 2026-02-08

## Context

The Mac transcription/dictation market has fractured into two pricing camps:

**Subscription apps:**
| App | Price | Annual Cost |
|-----|-------|-------------|
| WisprFlow | $12-15/mo | $144-180/year |
| Superwhisper | $5.41/mo (or $250 lifetime) | $65/year |
| Spokenly | $7.99/mo Pro | $96/year |

**One-time purchase apps:**
| App | Price | Tier |
|-----|-------|------|
| MacWhisper | $30 | Pro |
| VoiceInk | $39.99 | One-time (GPL open source) |
| BetterDictation | $39 (or $2/mo Pro) | One-time + optional sub |

Community sentiment -- particularly on Reddit, Hacker News, and Mac-focused forums -- overwhelmingly favors one-time purchases. Users express "subscription fatigue" and actively seek alternatives to subscription-based tools, especially for utilities that run locally and have no ongoing server costs.

## Decision

**$49 one-time purchase.** Free tier with 15 minutes/day of dictation. No subscription option.

### Pricing Structure

| Tier | Price | Limits |
|------|-------|--------|
| Free | $0 | 15 min/day dictation, basic clean mode only |
| Pro | $49 (one-time) | Unlimited dictation, all modes, command mode, file transcription, custom words, text snippets |

### Why $49

- **Above MacWhisper** ($30): Reflects more features -- command mode, LLM modes, dictation-first design
- **Above VoiceInk** ($39.99): Reflects file transcription, command mode, more processing modes
- **3-4 months of WisprFlow**: Users break even in 3-4 months vs WisprFlow's $12-15/mo. Easy value proposition.
- **Sweet spot for impulse purchase**: $49 is low enough for an impulse buy for professionals, high enough to signal quality

### Why no subscription

- Local-only processing (ADR-002) means zero marginal cost per user -- no servers to pay for
- Subscription requires ongoing justification; one-time purchase requires one moment of conviction
- Community sentiment strongly favors one-time for local tools
- Subscription fatigue is a real competitive advantage to exploit

## Rationale

### Market positioning

MacParakeet's positioning is: **"WisprFlow quality, local privacy, one-time price."**

The pricing model is a key part of this positioning. When a user searches "WisprFlow alternative" or "local dictation app Mac," the one-time price is immediately differentiating. It signals:

1. No ongoing cost commitment
2. The app works locally (no server costs to recoup)
3. Confidence in the product (we don't need to lock you in)

### Free tier as acquisition funnel

The 15 min/day free tier serves multiple purposes:

- **Try before you buy**: Users can evaluate STT quality, speed, and workflow fit without paying
- **Sufficient for light use**: 15 minutes covers casual dictation (emails, messages, short notes)
- **Natural upgrade trigger**: Users who exceed 15 min/day are heavy dictators who get clear value from Pro
- **No credit card required**: Reduces friction to zero for first-time users

### Revenue model

Revenue is front-loaded (one-time purchases spike at launch and after marketing pushes) rather than recurring. This is acceptable because:

- No server costs means low ongoing expenses
- Updates and improvements drive word-of-mouth and new user acquisition
- Potential for future paid upgrades (v2.0) if the market supports it
- App Store visibility drives steady organic acquisition

## Consequences

### Positive

- Strong differentiation against subscription competitors
- Zero ongoing cost for users after purchase
- Simple, transparent pricing builds trust
- Free tier drives organic growth and word-of-mouth
- No payment infrastructure complexity (App Store handles everything)
- Appeals to subscription-fatigued market segment

### Negative

- **Front-loaded revenue**: No recurring revenue stream. Must continuously acquire new users.
- **Update expectations**: One-time purchasers expect ongoing updates. Must balance development investment against diminishing returns.
- **No upsell path**: Unlike subscriptions, there's no natural path to increase revenue per user (unless we introduce paid major versions).
- **Price anchoring**: $49 sets an anchor. Raising the price later is difficult without grandfathering existing users.

### Mitigations

- **Steady content marketing and SEO** to maintain organic acquisition
- **Major version upgrades** (e.g., MacParakeet 2.0) can be separate paid products if needed
- **Referral incentives** to drive word-of-mouth acquisition
- **App Store featuring** through quality and good metadata

## Alternatives Considered

### Subscription only ($8-10/mo)
Rejected. No server costs make subscription pricing hard to justify. Community would immediately compare unfavorably to VoiceInk and MacWhisper.

### Freemium with subscription ($5/mo Pro)
Rejected. Low monthly price still triggers subscription aversion. Users would wait for a lifetime deal or switch to a one-time competitor.

### Lifetime + subscription hybrid (like Superwhisper)
Rejected. Superwhisper's $250 lifetime / $5.41/mo model confuses users and signals that the subscription is the "real" price. Simplicity wins.

### Higher one-time ($69-79)
Rejected. MacWhisper has dropped to $30 for Pro. At $49, MacParakeet is already priced above competitors -- the premium is justified by command mode, LLM integration, and dictation-first design, but going higher would reduce the impulse purchase appeal.

## References

- MacWhisper pricing: $30 (Pro)
- VoiceInk pricing: $39.99 (one-time)
- WisprFlow pricing: Free (2000 words/week), $15/mo or $12/mo annual (unlimited)
- Reddit r/macapps: consistent threads requesting one-time purchase alternatives to subscription tools
