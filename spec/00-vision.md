# MacParakeet Vision

> Status: **ACTIVE**

## One-Liner

The fastest, most private transcription app for Mac.

## Problem

Mac users who need transcription face a tradeoff:

1. **Cloud services** (Otter, Rev) - Fast but privacy nightmare, subscription fatigue
2. **Local apps** (MacWhisper, Superwhisper) - Private but expensive or complex
3. **Apple Dictation** - Free but slow, inaccurate, limited

**No app optimizes for: Speed + Privacy + Simplicity + Fair Pricing**

## Solution

MacParakeet is:
- **Fast** - Parakeet TDT transcribes 60 min audio in ~12 seconds
- **Private** - 100% local, zero cloud, zero accounts
- **Simple** - One-click transcription, no complexity
- **Fair** - One-time purchase (~$49-69), no subscription

## Target Users

### Primary: Privacy-Conscious Professionals
- Journalists handling sensitive sources
- Lawyers with confidential recordings
- Healthcare professionals (HIPAA concerns)
- Researchers with interview data

### Secondary: Power Users
- Podcasters transcribing episodes
- Content creators making captions
- Students transcribing lectures
- Writers preferring voice input

### Tertiary: MacWhisper Alternatives Seekers
- Users searching "MacWhisper alternative"
- People frustrated with subscriptions
- Those wanting simpler interface

## Market Position

```
                    HIGH ACCURACY
                         |
                         |
    MacWhisper ----------+---------- Otter.ai
    ($79, local)         |           ($16/mo, cloud)
                         |
                         |
   SIMPLE ---------------+--------------- COMPLEX
                         |
                         |
    MacParakeet ---------+---------- Superwhisper
    ($49, local, fast)   |           ($250, local)
                         |
                         |
                    LOW PRICE
```

**Our niche:** Simple + Fast + Private + Affordable

## Competitive Advantages

### 1. Parakeet-First Architecture
We built around Parakeet TDT from day one. Competitors added it as an afterthought.
- 6.3% WER vs Whisper's 7-12%
- 300x realtime vs Whisper's 15-30x
- Better technical vocabulary handling

### 2. One-Time Purchase
- MacWhisper: $79
- Superwhisper: $250 lifetime or $8/mo
- **MacParakeet: $49** (potential sweet spot)

### 3. Zero Accounts
No email, no login, no tracking. Download and use.

### 4. Focused Simplicity
MacWhisper has 50+ features. We have 5.
Less is more for users who just want transcription.

## Non-Goals

MacParakeet is NOT:
- A meeting app (that's Oatmeal)
- A note-taking app
- A cloud service
- An enterprise product
- A mobile app (initially)

## Success Metrics

| Metric | Target (Year 1) |
|--------|-----------------|
| Downloads | 10,000 |
| Paid conversions | 1,000 |
| Revenue | $49,000 |
| App Store rating | 4.5+ stars |

## Pricing Strategy

| Tier | Price | Features |
|------|-------|----------|
| Free | $0 | 15 min/day, small model |
| Pro | $49 | Unlimited, all models, export |

No subscriptions. No feature gates. Simple.

## Relationship to Oatmeal

```
┌─────────────────────────────────────────────────────┐
│                    Shared Core                       │
│  ┌───────────────────────────────────────────────┐  │
│  │  parakeet-mlx (STT daemon)                    │  │
│  │  MLX-Swift (LLM integration)                  │  │
│  │  Audio processing utilities                    │  │
│  └───────────────────────────────────────────────┘  │
├─────────────────────┬───────────────────────────────┤
│    MacParakeet      │         Oatmeal               │
│    (Transcription)  │         (Meeting Memory)      │
│                     │                               │
│  • File → Text      │  • Calendar integration       │
│  • Dictation        │  • Entity extraction          │
│  • Simple export    │  • Cross-meeting memory       │
│                     │  • Action items               │
│  Simple, focused    │  Complex, powerful            │
│  $49 one-time       │  Freemium + Pro               │
└─────────────────────┴───────────────────────────────┘
```

MacParakeet can be:
- Standalone product for transcription users
- Entry point to Oatmeal ecosystem
- Revenue stream while Oatmeal matures

## Timeline

| Phase | Scope | Target |
|-------|-------|--------|
| v0.1 | MVP - Core transcription + dictation | 2 weeks |
| v0.2 | AI refinement + YouTube import | +2 weeks |
| v0.3 | Polish + App Store submission | +1 week |
| Launch | macparakeet.com + App Store | Week 6 |

## Key Decisions

1. **macOS only** - Focus beats breadth
2. **Apple Silicon only** - Parakeet needs Metal
3. **No cloud option** - Privacy is the brand
4. **One-time purchase** - Differentiator vs subscriptions
5. **SwiftUI native** - Best Mac experience

---

*"Fast. Private. Simple. That's MacParakeet."*
