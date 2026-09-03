import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import AccountAnonymizerDeleteModal from "discourse/components/account-anonymizer-delete-modal";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class AccountAnonymizerDeleteConnector extends Component {
  @service currentUser;
  @service modal;

  get shouldShow() {
    return (
      this.currentUser?.can_self_anonymize_account &&
      this.args.outletArgs.model?.id === this.currentUser.id
    );
  }

  @action
  openModal() {
    this.modal.show(AccountAnonymizerDeleteModal);
  }

  <template>
    {{#if this.shouldShow}}
      <div class="control-group account-anonymizer-delete-account">
        <br />
        <div class="controls">
          <DButton
            @action={{this.openModal}}
            @icon="trash-can"
            @label="account_anonymizer.button"
            class="btn-danger"
          />
        </div>
      </div>
    {{/if}}
  </template>
}
