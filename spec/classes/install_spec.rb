# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose::install' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }
      let(:pre_condition) { 'include podman_compose' }

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to contain_package('podman').with_ensure('installed') }

      context 'with compose_install_method => pip' do
        let(:pre_condition) do
          "class { 'podman_compose': compose_install_method => 'pip' }"
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_exec('pip-install-podman-compose') }
      end

      context 'with manage_package => false' do
        let(:pre_condition) do
          "class { 'podman_compose': manage_package => false }"
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_package('podman') }
      end
    end
  end
end
