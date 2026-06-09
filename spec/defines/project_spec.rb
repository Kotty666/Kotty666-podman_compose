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

        it 'tears down even a legacy docker-compose.yml project' do
          down = catalogue.resource('Exec', 'podman-compose-down-demo')
          # Falls back to the legacy filename when compose.yml is absent...
          expect(down[:command]).to match(%r{docker-compose\.yml})
          # ...and the guard fires when either file exists.
          expect(down[:onlyif]).to match(%r{compose\.yml.*docker-compose\.yml})
        end
      end

      context 'recreate_strategy (rootful)' do
        let(:base) do
          {
            'rootless' => false,
            'compose'  => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
          }
        end

        context 'default is force-recreate' do
          let(:params) { base }

          it { is_expected.to compile.with_all_deps }

          it 'force-recreates containers so env changes are applied cleanly' do
            is_expected.to contain_exec('podman-compose-restart-demo')
              .with_command(%r{up -d --force-recreate --remove-orphans})
          end
        end

        context 'rolling' do
          let(:params) { base.merge('recreate_strategy' => 'rolling') }

          it 'uses a plain up -d without force-recreate' do
            cmd = catalogue.resource('Exec', 'podman-compose-restart-demo')[:command]
            expect(cmd).to match(%r{up -d --remove-orphans})
            expect(cmd).not_to match(%r{--force-recreate})
          end
        end

        context 'down-up' do
          let(:params) { base.merge('recreate_strategy' => 'down-up') }

          it 'tears the project down then up so networks are re-created' do
            is_expected.to contain_exec('podman-compose-restart-demo')
              .with_command(%r{down && .* up -d --remove-orphans})
          end
        end
      end

      context 'recreate_strategy (rootless)' do
        let(:params) do
          {
            'rootless'          => true,
            'user'              => 'appuser',
            'recreate_strategy' => 'down-up',
            'compose'           => { 'services' => { 'web' => { 'image' => 'nginx:1.27' } } },
          }
        end

        it { is_expected.to compile.with_all_deps }

        it 'wraps the down-up sequence for the project user' do
          is_expected.to contain_exec('podman-compose-restart-demo')
            .with_command(%r{down && .* up -d --remove-orphans})
        end
      end
    end
  end
end
