import Component from "@glimmer/component";
import { action } from "@ember/object";
import { next } from "@ember/runloop";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import AccountAnonymizerDeleteModal from "discourse/components/account-anonymizer-delete-modal";
import { ajax } from "discourse/lib/ajax";
import getURL from "discourse/lib/get-url";
import DiscourseURL, { userPath } from "discourse/lib/url";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class AccountAnonymizerDeleteConnector extends Component {
  @service currentUser;
  @service dialog;
  @service modal;

  @tracked checking = false;

  get viewingSelf() {
    return (
      this.currentUser &&
      this.args.outletArgs.model?.id === this.currentUser.id
    );
  }

  get isStaff() {
    return this.currentUser?.admin || this.currentUser?.moderator;
  }

  @action
  async deleteAccount() {
    if (this.checking) {
      return;
    }

    this.checking = true;

    let status;
    try {
      status = await ajax("/account-anonymizer/status.json");
    } catch {
      this.dialog.alert(i18n("account_anonymizer.status_error"));
      this.checking = false;
      return;
    }

    this.checking = false;

    if (status?.mode === "anonymize") {
      this.modal.show(AccountAnonymizerDeleteModal);
      return;
    }

    if (status?.mode === "native_delete") {
      this.confirmNativeDelete();
      return;
    }

    this.dialog.alert(i18n("user.delete_yourself_not_allowed"));
  }

  confirmNativeDelete() {
    this.dialog.alert({
      message: i18n("user.delete_account_confirm"),
      buttons: [
        {
          icon: "triangle-exclamation",
          label: i18n("user.delete_account"),
          class: "btn-danger",
          action: () => this.performNativeDelete(),
        },
        {
          label: i18n("composer.cancel"),
        },
      ],
    });
  }

  async performNativeDelete() {
    this.checking = true;

    try {
      // Re-check immediately before invoking core deletion. This keeps a user
      // who gained content after opening the confirmation out of the native
      // delete path and sends them through anonymization on their next click.
      const status = await ajax("/account-anonymizer/status.json");
      if (status?.mode !== "native_delete") {
        this.checking = false;
        this.dialog.alert(i18n("account_anonymizer.status_changed"));
        return;
      }

      const model = this.args.outletArgs.model;
      await ajax(userPath(`${model.username}.json`), {
        type: "DELETE",
        data: { context: window.location.pathname },
      });

      next(() => {
        this.dialog.alert({
          message: i18n("user.deleted_yourself"),
          didConfirm: () => DiscourseURL.redirectAbsolute(getURL("/")),
          didCancel: () => DiscourseURL.redirectAbsolute(getURL("/")),
        });
      });
    } catch {
      this.checking = false;
      next(() => this.dialog.alert(i18n("user.delete_yourself_not_allowed")));
    }
  }

  <template>
    {{#if this.viewingSelf}}
      <div class="account-anonymizer-controls">
        {{#unless this.isStaff}}
          <div class="control-group account-anonymizer-delete-account">
            <br />
            <div class="controls">
              <DButton
                @action={{this.deleteAccount}}
                @disabled={{this.checking}}
                @loading={{this.checking}}
                @icon="trash-can"
                @label="user.delete_account"
                class="btn-danger"
              />
            </div>
          </div>
        {{/unless}}
      </div>
    {{/if}}
  </template>
}
