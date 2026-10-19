import unittest

from check_commit_policy import violations


def commit(message="Fix link cleaning", author="123+human@users.noreply.github.com", committer=None):
    return {"sha": "a" * 40, "commit": {"message": message,
            "author": {"email": author}, "committer": {"email": committer or author}}}


class CommitPolicyTests(unittest.TestCase):
    def test_human_commits_are_allowed(self):
        self.assertEqual([], violations([commit(), commit("Fix Android\n\nKeep the URL intact.")]))

    def test_trailer_in_any_commit_is_rejected(self):
        self.assertTrue(violations([commit("Fix Android\n\nCo-Authored-By: Assistant <noreply@anthropic.com>"), commit()]))

    def test_case_and_spacing_do_not_bypass_policy(self):
        self.assertTrue(violations([commit("Fix Android\r\n\r\n  cO-aUtHoReD-bY : Someone <user@example.invalid>\r\n")]))

    def test_ai_author_and_committer_are_rejected(self):
        self.assertTrue(violations([commit(author="NOREPLY@ANTHROPIC.COM")]))
        self.assertTrue(violations([commit(committer="noreply@openai.com")]))

    def test_mentioning_the_policy_is_allowed(self):
        self.assertEqual([], violations([commit("Reject Co-Authored-By trailers in pull requests")]))
