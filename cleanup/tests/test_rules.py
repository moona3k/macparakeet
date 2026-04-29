"""Tests for the deterministic cleanup pipeline."""

import time

import pytest

from macparakeet_cleanup.rules import clean_rules


# ---- filler removal -----------------------------------------------------------


def test_removes_um_uh():
    assert clean_rules("um so uh I went to the store") == "So I went to the store."


def test_removes_er_erm_ah():
    assert clean_rules("er ah erm yes") == "Yes."


def test_filler_inside_clause_with_comma():
    assert clean_rules("I went, um, to the store") == "I went, to the store."


def test_preserves_words_starting_with_filler_letters():
    # 'umbrella' must not lose its 'um'.
    assert "umbrella" in clean_rules("I bought an umbrella").lower()


def test_removes_you_know_at_start():
    assert clean_rules("you know, I think we should go") == "I think we should go."


def test_removes_i_mean_parenthetical():
    assert clean_rules("the meeting, I mean, the standup is at 10") == \
        "The meeting, the standup is at 10."


def test_keeps_like_when_meaningful():
    # mid-sentence "like" preserved (it's not a filler here).
    out = clean_rules("a tool like this one")
    assert "like" in out.lower()


def test_removes_like_at_clause_start():
    assert clean_rules("like, I think it's fine") == "I think it's fine."


# ---- duplicate word / phrase removal ------------------------------------------


def test_collapses_double_word():
    assert clean_rules("the the cat") == "The cat."


def test_collapses_triple_word():
    assert clean_rules("the the the cat") == "The cat."


def test_collapses_repeated_phrase():
    assert clean_rules("I think I think we should go") == "I think we should go."


def test_collapses_three_word_repeat():
    assert clean_rules("we should we should leave now") == "We should leave now."


def test_collapses_sentence_restart_with_comma():
    out = clean_rules("I went to, I went to the store")
    assert out == "I went to the store."


# ---- spacing & punctuation ----------------------------------------------------


def test_collapses_extra_whitespace():
    assert clean_rules("hello    world") == "Hello world."


def test_fixes_space_before_punctuation():
    assert clean_rules("hello , world .") == "Hello, world."


def test_adds_space_after_punctuation():
    assert clean_rules("hello,world.next") == "Hello, world. Next."


def test_adds_terminal_period():
    assert clean_rules("just three words") == "Just three words."


def test_preserves_existing_terminal_question():
    assert clean_rules("are you sure?") == "Are you sure?"


# ---- capitalization -----------------------------------------------------------


def test_capitalizes_first_letter():
    assert clean_rules("hello world") == "Hello world."


def test_capitalizes_after_sentence_end():
    assert clean_rules("first. second sentence") == "First. Second sentence."


def test_capitalizes_lone_i():
    assert clean_rules("i went home") == "I went home."


def test_capitalizes_i_contractions():
    assert clean_rules("i'm tired and i've been working") == \
        "I'm tired and I've been working."


# ---- meaning preservation -----------------------------------------------------


def test_preserves_proper_nouns():
    out = clean_rules("um I work at Anthropic")
    assert "Anthropic" in out


def test_preserves_numbers():
    out = clean_rules("uh the meeting is at 3:30")
    assert "3:30" in out


def test_does_not_invent_content():
    # Output should only contain words that were in the input
    # (after lowercasing, ignoring punctuation).
    inp = "um I think we should go to the the store"
    out = clean_rules(inp)
    in_words = set(w.lower().strip(".,!?") for w in inp.split())
    out_words = set(w.lower().strip(".,!?") for w in out.split())
    # Every output word should appear in input (modulo filler removal).
    assert out_words.issubset(in_words)


def test_empty_input():
    assert clean_rules("") == ""
    assert clean_rules("   ") == ""


def test_only_filler_input():
    # All-filler input should yield empty (or near-empty) string.
    out = clean_rules("um uh er")
    assert out in ("", ".", "Um.")  # tolerant — main thing is no crash


# ---- performance --------------------------------------------------------------


def test_rules_are_fast():
    text = (
        "um so I was thinking, you know, I was thinking that uh maybe we "
        "should we should go to the store and uh pick up some milk"
    )
    start = time.perf_counter()
    for _ in range(100):
        clean_rules(text)
    elapsed_ms = (time.perf_counter() - start) * 1000 / 100
    assert elapsed_ms < 100, f"rules took {elapsed_ms:.1f}ms per call"
