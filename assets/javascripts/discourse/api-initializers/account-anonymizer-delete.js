import { action } from "@ember/object";
import AccountAnonymizerDeleteModal from "discourse/components/account-anonymizer-delete-modal";
import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";

export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");

  if (!siteSettings.account_anonymizer_enabled) {
    return;
  }

  api.modifyClass("controller:preferences/account", (Superclass) => {
    // Fail closed if Discourse changes the account controller contract in a
    // future release. Do not replace an unknown native delete implementation.
    if (typeof Superclass.prototype.delete !== "function") {
      return class extends Superclass {};
    }

    return class extends Superclass {
      @action
      async delete(...args) {
        let status;

        try {
          status = await ajax("/account-anonymizer/status.json");
        } catch {
          this.dialog.alert(i18n("account_anonymizer.status_error"));
          return;
        }

        if (status?.mode === "anonymize") {
          this.modal.show(AccountAnonymizerDeleteModal);
          return;
        }

        if (
          status?.mode === "native_delete" ||
          status?.mode === "unavailable"
        ) {
          return super.delete(...args);
        }

        this.dialog.alert(i18n("account_anonymizer.status_error"));
      }
    };
  });
});
