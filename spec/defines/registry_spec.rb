# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose::registry' do
  let(:title) { 'appuser@registry.example.com' }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'present, rootless' do
        let(:params) do
          {
            'server'   => 'registry.example.com',
            'username' => 'deploy',
            'password' => sensitive('s3cret'),
            'user'     => 'appuser',
            'rootless' => true,
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_exec('podman-login-appuser-registry.example.com').with_refreshonly(true) }
      end

      context 'absent' do
        let(:params) do
          {
            'server'   => 'registry.example.com',
            'username' => 'deploy',
            'password' => sensitive('s3cret'),
            'user'     => 'appuser',
            'rootless' => true,
            'ensure'   => 'absent',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_exec('podman-logout-appuser-registry.example.com') }
      end
    end
  end
end
