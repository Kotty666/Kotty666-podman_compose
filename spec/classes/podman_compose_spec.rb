# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to contain_class('podman_compose::install') }
      it { is_expected.to contain_package('podman') }

      context 'with a project defined' do
        let(:params) do
          {
            'projects' => {
              'demo' => {
                'rootless' => false,
                'compose'  => {
                  'services' => {
                    'web' => { 'image' => 'nginx:1.27' },
                  },
                },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__project('demo') }
      end

      context 'with a cron project defined' do
        let(:params) do
          {
            'cron_projects' => {
              'job' => {
                'rootless'    => false,
                'on_calendar' => 'daily',
                'compose'     => {
                  'services' => {
                    'task' => { 'image' => 'busybox:latest' },
                  },
                },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__cron('job') }
      end

      context 'with an autoscaler defined' do
        let(:params) do
          {
            'autoscalers' => {
              'api' => {
                'rootless' => false,
                'service'  => 'api',
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__autoscale('api') }
      end
    end
  end
end
