# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose::user' do
  let(:title) { 'appuser' }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with manage_subid and explicit ranges' do
        let(:params) do
          {
            'subuid_start' => 100_000,
            'subgid_start' => 100_000,
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_user('appuser').with_managehome(true) }
        it { is_expected.to contain_exec('loginctl-enable-linger-appuser') }
        it { is_expected.to contain_exec('start-user-manager-appuser') }
        it { is_expected.to contain_exec('subuid-appuser') }
        it { is_expected.to contain_exec('subgid-appuser') }
      end

      context 'with manage_subid disabled' do
        let(:params) { { 'manage_subid' => false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_exec('subuid-appuser') }
        it { is_expected.not_to contain_exec('subgid-appuser') }
      end

      context 'with manage_subid true but missing subuid_start' do
        let(:params) { { 'manage_subid' => true } }

        it { is_expected.to compile.and_raise_error(%r{subuid_start and subgid_start must be set}) }
      end
    end
  end
end
