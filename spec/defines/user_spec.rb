# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose::user' do
  let(:title) { 'appuser' }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to contain_user('appuser').with_managehome(true) }
      it { is_expected.to contain_exec('loginctl-enable-linger-appuser') }
      it { is_expected.to contain_exec('start-user-manager-appuser') }
    end
  end
end
