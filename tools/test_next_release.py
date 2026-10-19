import unittest
from next_release import choose


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.releases = [{"tag_name": "v0.2.1", "target_commitish": "old", "draft": False, "prerelease": False}]

    def test_new_notes_select_the_planned_minor_release(self):
        result = choose(self.releases, ["v0.1.0", "v0.2.1", "v0.3.0"], "branch", "main", "new")
        self.assertEqual(result, {"publish": "true", "tag": "v0.3.0", "number": "0.3.0"})

    def test_normal_merge_gets_the_next_patch(self):
        self.assertEqual(choose(self.releases, ["v0.2.1"], "branch", "main", "new")["tag"], "v0.2.2")

    def test_rerunning_a_published_commit_does_not_create_another_version(self):
        self.assertEqual(choose(self.releases, [], "branch", "main", "old"), {"publish": "false"})

    def test_incomplete_draft_is_retried_at_the_same_version(self):
        self.releases.append({"tag_name": "v0.2.2", "target_commitish": "new", "draft": True})
        self.assertEqual(choose(self.releases, [], "branch", "main", "new")["tag"], "v0.2.2")

    def test_explicit_tags_are_honored_and_existing_releases_are_skipped(self):
        self.assertEqual(choose(self.releases, [], "tag", "v1.0.0", "new")["tag"], "v1.0.0")
        self.assertEqual(choose(self.releases, [], "tag", "v0.2.1", "new")["publish"], "false")
        with self.assertRaises(ValueError):
            choose(self.releases, [], "tag", "vnot-a-version", "new")

    def test_latest_version_is_numeric_and_ignores_prereleases(self):
        releases = [{"tag_name": "v0.9.9"}, {"tag_name": "v0.10.0"},
                    {"tag_name": "v1.0.0", "prerelease": True}]
        self.assertEqual(choose(releases, [], "branch", "main", "new")["tag"], "v0.10.1")


if __name__ == "__main__":
    unittest.main()
