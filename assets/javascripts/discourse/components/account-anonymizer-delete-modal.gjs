import Component from "@glimmer/component";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import getURL from "discourse/lib/get-url";
import DiscourseURL from "discourse/lib/url";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

export default class AccountAnonymizerDeleteModal extends Component {
  @tracked password = "";
  @tracked saving = false;
  @tracked error = null;

  get deleteDisabled() {
    return this.saving || this.password.length === 0;
  }

  @action
  updatePassword(event) {
    this.password = event.target.value;
    this.error = null;
  }

  @action
  async deleteAccount() {
    if (this.deleteDisabled) {
      return;
    }

    this.saving = true;
    this.error = null;

    try {
      await ajax("/account-anonymizer/anonymize.json", {
        type: "POST",
        data: { password: this.password },
      });

      this.password = "";
      DiscourseURL.redirectAbsolute(getURL("/"));
    } catch (error) {
      this.error = extractError(error);
      this.password = "";
      this.saving = false;
    }
  }

  <template>
    <DModal
      @closeModal={{@closeModal}}
      @title={{i18n "account_anonymizer.title"}}
      class="account-anonymizer-modal"
    >
      <:body>
        <div class="alert alert-error account-anonymizer-modal__warning">
          {{i18n "account_anonymizer.warning"}}
        </div>

        <p class="account-anonymizer-modal__retained-content">
          {{i18n "account_anonymizer.retained_content"}}
        </p>

        <div class="account-anonymizer-modal__password-field">
          <label for="account-anonymizer-password">
            {{i18n "account_anonymizer.password_label"}}
          </label>
          <input
            id="account-anonymizer-password"
            class="input-xxlarge"
            type="password"
            value={{this.password}}
            autocomplete="current-password"
            disabled={{this.saving}}
            {{on "input" this.updatePassword}}
          />
          <div class="instructions">
            {{i18n "account_anonymizer.password_help"}}
          </div>
        </div>

        {{#if this.error}}
          <div class="alert alert-error account-anonymizer-modal__error">
            {{this.error}}
          </div>
        {{/if}}
      </:body>

      <:footer>
        <DButton
          @action={{this.deleteAccount}}
          @disabled={{this.deleteDisabled}}
          @loading={{this.saving}}
          @icon="trash-can"
          @label="account_anonymizer.confirm"
          class="btn-danger"
        />
        <DButton
          @action={{@closeModal}}
          @disabled={{this.saving}}
          @label="account_anonymizer.cancel"
          class="btn-flat"
        />
      </:footer>
    </DModal>
  </template>
}
