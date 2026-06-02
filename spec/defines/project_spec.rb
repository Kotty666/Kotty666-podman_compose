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

      context 'shared user across multiple projects' do
        # Regression: two rootless projects owned by the same user must not
        # raise a duplicate Podman_compose::User declaration.
        let(:pre_condition) do
          <<~PP
            include podman_compose
            podman_compose::project { 'other':
              rootless => true,
              user     => 'appuser',
              compose  => { 'services' => { 'api' => { 'image' => 'busybox' } } },
            }
          PP
        end
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

      context 'shared registry across multiple projects' do
        # Regression: two rootless projects sharing the same user and
        # registry must not raise a duplicate Podman_compose::Registry
        # declaration, even though their compose dirs differ.
        let(:pre_condition) do
          <<~PP
            include podman_compose
            podman_compose::project { 'other':
              rootless   => true,
              user       => 'appuser',
              registries => { 'harbor.example' => { 'username' => 'robot', 'password' => Sensitive('secret') } },
              compose    => { 'services' => { 'api' => { 'image' => 'harbor.example/api' } } },
            }
          PP
        end
        let(:params) do
          {
            'rootless'   => true,
            'user'       => 'appuser',
            'registries' => { 'harbor.example' => { 'username' => 'robot', 'password' => sensitive('secret') } },
            'compose'    => {
              'services' => {
                'web' => { 'image' => 'harbor.example/web' },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__registry('appuser@harbor.example') }
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
