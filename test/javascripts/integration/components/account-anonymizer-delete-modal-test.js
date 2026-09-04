import { module, test } from "qunit";
import AccountAnonymizerDeleteModal from "discourse/plugins/Discourse-Account-Anonymizer-Plugin/discourse/components/account-anonymizer-delete-modal";

module("discourse-account-anonymizer | component module", function () {
  test("delete modal resolves from the plugin namespace", function (assert) {
    assert.ok(AccountAnonymizerDeleteModal);
  });
});
