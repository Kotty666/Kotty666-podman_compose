# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose::project' do
  let(:title) { 'demo' }
  let(:pre_condition) { 'include podman_compose' }

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'rootful, minimal compose' do
        let(:params) do
          {
            'rootless' => false,
            'compose'  => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/opt/compose/demo') }
        it { is_expected.to contain_file('/etc/systemd/system/podman-compose-demo.service') }
      end

      context 'rootless requires user' do
        let(:params) do
          {
            'rootless' => true,
            'compose'  => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{'user' is required when rootless}) }
      end

      context 'rootless with user' do
        let(:params) do
          {
            'rootless' => true,
            'user'     => 'appuser',
            'compose'  => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__user('appuser') }
      end

      context 'compose hash missing services' do
        let(:params) do
          {
            'rootless' => false,
            'compose'  => { 'version' => '3' },
          }
        end

        it { is_expected.to compile.and_raise_error(%r{must contain a 'services' key}) }
      end

      context 'ensure => absent' do
        let(:params) do
          {
            'ensure'   => 'absent',
            'rootless' => false,
            'compose'  => {
              'services' => {
                'web' => { 'image' => 'nginx:1.27' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/opt/compose/demo').with_ensure('absent') }
      end
    end
  end
end
